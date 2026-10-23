#Requires -Version 5.1
# Shared, side-effect-free helpers. Dot-sourcing this file does not run a migration.

function Get-MigrationProperty {
    param([AllowNull()][object]$InputObject, [string]$Name, [object]$Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
    } elseif ($InputObject.PSObject.Properties[$Name]) { return $InputObject.$Name }
    return $Default
}

function Resolve-MigrationStateDirectory {
    param([string]$StateDirectory, [string]$SearchRoot = 'C:\', [string]$ComputerName = $env:COMPUTERNAME)
    if ($StateDirectory) {
        foreach ($file in @('PreMigrationState.json', 'NetworkConfiguration.json')) {
            if (-not (Test-Path -LiteralPath (Join-Path $StateDirectory $file) -PathType Leaf)) {
                throw "Missing $file in the selected state directory: $StateDirectory"
            }
        }
        return (Get-Item -LiteralPath $StateDirectory -ErrorAction Stop).FullName
    }
    $candidates = @(
        foreach ($root in @(Get-ChildItem -LiteralPath $SearchRoot -Directory -Filter 'Rutin_migration_*' -ErrorAction Stop)) {
            foreach ($export in @(Get-ChildItem -LiteralPath $root.FullName -Directory -Filter 'Export-MigrationState*' -ErrorAction Stop)) {
                $state = Join-Path $export.FullName 'State'
                $json = Join-Path $state 'PreMigrationState.json'
                if (-not (Test-Path -LiteralPath $json -PathType Leaf)) { continue }
                try {
                    $data = Get-Content -LiteralPath $json -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($data.systemIdentity.computerName -ine $ComputerName) { continue }
                    [pscustomobject]@{ path = $state; captured = [DateTimeOffset]::Parse($data.capturedAtUtc).UtcDateTime }
                } catch { throw "Cannot inspect capture '$json'. Select a known complete -StateDirectory explicitly. $($_.Exception.Message)" }
            }
        }
    )
    if ($candidates.Count -eq 0) { throw 'No matching migration capture found. Supply -StateDirectory explicitly.' }
    $ordered = @($candidates | Sort-Object captured -Descending)
    if ($ordered.Count -gt 1 -and $ordered[0].captured -eq $ordered[1].captured) {
        throw 'Multiple captures have the same latest timestamp. Supply -StateDirectory explicitly.'
    }
    # Do not silently fall back to an older capture if the newest capture is incomplete.
    return Resolve-MigrationStateDirectory -StateDirectory $ordered[0].path
}

function Get-MigrationFirstbootState {
    param([string]$Path = 'C:\Program Files\Guestfs\Firstboot')
    $candidates = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Where-Object {
        $_.Name -match 'firstboot' -or $_.PathName -match 'Guestfs[\\/]Firstboot'
    })
    $services = @(); $installedServices = @()
    foreach ($candidate in $candidates) {
        $name = [string](Get-MigrationProperty $candidate 'Name' '')
        $servicePath = [string](Get-MigrationProperty $candidate 'PathName' '')
        $executable = ''
        if ($servicePath -match '^\s*(?:"(?<exe>[^"]+\.exe)"|(?<exe>.+?\.exe))(?=\s|$)') {
            $executable = [IO.Path]::GetFileName(($Matches['exe'] -replace '\\', '/'))
        }
        $record = [pscustomobject]@{
            name = $name
            state = [string](Get-MigrationProperty $candidate 'State' 'Unknown')
            startMode = [string](Get-MigrationProperty $candidate 'StartMode' 'Unknown')
            pathName = $servicePath
        }
        # Conversion can leave Balloon/QEMU Agent installed below Firstboot.
        # These installed payloads are not the firstboot runner. Only recognize
        # their actual executable, never a filename appearing in arguments.
        if ($name -notmatch 'firstboot' -and $executable -in @('blnsvr.exe', 'qemu-ga.exe')) {
            $installedServices += $record
        } else {
            # Firstboot-named services and unrecognized services in its directory
            # remain blocking, including stopped services awaiting cleanup.
            $services += $record
        }
    }
    $exists = Test-Path -LiteralPath $Path -PathType Container
    $pending = @()
    $logs = @()
    if ($exists -and (Test-Path -LiteralPath (Join-Path $Path 'scripts') -PathType Container)) {
        $files = @(Get-ChildItem -LiteralPath (Join-Path $Path 'scripts') -File -ErrorAction Stop)
        # Installers can leave balloon.log here after the runner has moved its
        # batch scripts to scripts-done. A log is not outstanding execution work.
        # Keep unrecognized non-log files blocking rather than assuming completion.
        $logs = @($files | Where-Object { $_.Extension -ieq '.log' })
        $pending = @($files | Where-Object { $_.Extension -ine '.log' })
    }
    $log = Join-Path $Path 'log.txt'
    $lastLine = ''
    if (Test-Path -LiteralPath $log -PathType Leaf) {
        $lastLine = [string](Get-Content -LiteralPath $log -Tail 20 -ErrorAction Stop | Where-Object { $_.Trim() } | Select-Object -Last 1)
    }
    $complete = Test-Path -LiteralPath (Join-Path $Path 'complete') -PathType Leaf
    $state = 'Unknown'
    if ($services.Count -gt 0 -or $pending.Count -gt 0) { $state = 'Pending' }
    elseif (-not $exists) { $state = 'NotDetected' }
    elseif ($complete -or $lastLine -match '^Service uninstalled successfully\s*$') { $state = 'Complete' }
    [pscustomobject]@{ state = $state; serviceCount = $services.Count; services = $services; installedPayloadServices = $installedServices; pendingScripts = @($pending | ForEach-Object Name); ignoredLogFiles = @($logs | ForEach-Object Name); completeMarkerPresent = [bool]$complete; lastLogLine = $lastLine; path = $Path }
}

function Assert-MigrationFirstbootComplete {
    param([switch]$FirstbootNotUsed)
    $status = Get-MigrationFirstbootState
    if ($status.state -eq 'Complete') { return $status }
    if ($status.state -eq 'NotDetected' -and $FirstbootNotUsed) { return $status }
    if ($status.state -eq 'NotDetected') {
        throw 'Firstboot completion cannot be established. Use -FirstbootNotUsed only for a restore method that does not use Guestfs/Firstboot.'
    }
    $details = @("[MIG-FIRSTBOOT-001] Firstboot is $($status.state). Wait for conversion to finish or investigate its log.")
    $blockingServices = @(Get-MigrationProperty $status 'services' @() | Where-Object { $_ })
    if ($blockingServices.Count) {
        $details += 'Blocking service(s):'
        foreach ($service in $blockingServices) { $details += "  $($service.name): state=$($service.state), start=$($service.startMode), path=$($service.pathName)" }
    } else { $details += 'Blocking services: none reported.' }
    $scripts = @(Get-MigrationProperty $status 'pendingScripts' @() | Where-Object { $_ })
    $unfinishedServices = @($blockingServices | Where-Object { $_.name -notmatch 'firstboot' -or $_.state -ne 'Running' -or $_.startMode -ne 'Disabled' })
    if ($status.state -eq 'Pending' -and $scripts.Count -eq 0 -and $blockingServices.Count -gt 0 -and $unfinishedServices.Count -eq 0 -and
        [string](Get-MigrationProperty $status 'lastLogLine' '') -match '^Service uninstalled successfully\s*$') {
        $details[0] = '[MIG-FIRSTBOOT-002] Firstboot cleanup appears to be awaiting service removal; completion is still blocked.'
        $details += 'No pending scripts remain, but the Firstboot service is still Running and Disabled after a successful uninstall log entry. It may be marked for deletion.'
        $details += 'Action: restart Windows once using the Start menu in the Proxmox console, then run 3) ValidatePost again. If still blocked after restart, investigate the Firstboot log. No automatic restart or service deletion was performed.'
    }
    $details += 'Pending scripts: ' + $(if ($scripts.Count) { $scripts -join ', ' } else { 'none' })
    $details += "Completion marker present: $(Get-MigrationProperty $status 'completeMarkerPresent' $false)"
    $details += "Last Firstboot log line: $(Get-MigrationProperty $status 'lastLogLine' '<not available>')"
    $details += "Log path: $(Get-MigrationProperty $status 'path' 'C:\Program Files\Guestfs\Firstboot')\log.txt"
    throw ($details -join [Environment]::NewLine)
}

function Get-MigrationRouteProtocol {
    param([object]$Route, [ValidateSet('ActiveStore', 'PersistentStore')][string]$PolicyStore = 'ActiveStore')
    $protocol = Get-MigrationProperty $Route 'Protocol'
    if ([string]::IsNullOrWhiteSpace([string]$protocol) -or [string]$protocol -in @('65535', 'Unknown')) {
        # Server 2019 may expose null/65535 Protocol for saved routes. The explicit
        # PersistentStore query proves these are saved route settings, independent
        # of whether a corresponding active route currently exists.
        if ($PolicyStore -eq 'PersistentStore') { return 'NetMgmt' }
        throw 'An ActiveStore route has no usable Protocol; route classification is unsafe.'
    }
    switch ([string]$protocol) {
        '2' { return 'Local' }
        '3' { return 'NetMgmt' }
        default { return [string]$protocol }
    }
}

function Assert-MigrationNetworkCaptureComplete {
    param([AllowNull()][object]$Network)
    $adapters = @(Get-MigrationProperty $Network 'activeAdapters' @() | Where-Object { $_ })
    if ($adapters.Count -eq 0) { throw 'Network capture contains no active adapters. Preparation cannot be approved; inspect the network capture errors and rerun Prepare.' }
    if ((Get-MigrationProperty $Network 'routeCaptureComplete' $true) -ne $true) {
        throw 'Network route capture is incomplete. Preparation cannot be approved; inspect the network capture errors and rerun Prepare.'
    }
    # An empty route array is valid; a missing property is an incomplete capture.
    $hasRoutes = if ($Network -is [System.Collections.IDictionary]) { $Network.Contains('ipv4Routes') }
        else { $null -ne $Network -and $null -ne $Network.PSObject.Properties['ipv4Routes'] }
    if (-not $hasRoutes -or $null -eq $Network.ipv4Routes) {
        throw 'Network capture is missing ipv4Routes. Preparation cannot be approved; rerun Prepare.'
    }
}

function Get-MigrationAutomaticDns {
    param([guid]$InterfaceGuid)
    # Get-NetAdapter may expose a Guid object or a brace-wrapped string. Registry
    # interface keys always use braces, so format explicitly rather than interpolate.
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $InterfaceGuid.ToString('B')
    $registry = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    return [string]::IsNullOrWhiteSpace([string](Get-MigrationProperty $registry 'NameServer' ''))
}

function ConvertTo-MigrationMacAddress {
    param([AllowNull()][string]$MacAddress)
    $normalized = ($MacAddress -replace '[-:]', '').ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{12}$' -or $normalized -in @('000000000000', 'FFFFFFFFFFFF')) {
        throw "Missing or invalid MAC address: '$MacAddress'."
    }
    if (([Convert]::ToInt32($normalized.Substring(0, 2), 16) -band 1) -ne 0) {
        throw "Multicast MAC addresses cannot identify a target NIC: '$MacAddress'."
    }
    return $normalized
}

function Get-MigrationNetRoutes {
    param([string]$PolicyStore = 'ActiveStore', [Nullable[int]]$InterfaceIndex)
    $arguments = @{ AddressFamily = 'IPv4'; PolicyStore = $PolicyStore; ErrorAction = 'Stop' }
    if ($null -ne $InterfaceIndex) { $arguments.InterfaceIndex = [int]$InterfaceIndex }
    try { Get-NetRoute @arguments }
    catch {
        # CDXML reports an empty filtered query as an error on some Windows builds.
        # Authentication, provider, and other failures must still block restoration.
        if ($_.FullyQualifiedErrorId -notmatch '^CmdletizationQuery_NotFound') { throw }
    }
}

function Get-MigrationEventErrors {
    param([string]$LogName, [datetime]$StartTime, [int]$MaxEvents = 200)
    try {
        Get-WinEvent -FilterHashtable @{ LogName = $LogName; Level = 1, 2; StartTime = $StartTime } -MaxEvents $MaxEvents -ErrorAction Stop
    } catch {
        if ($_.FullyQualifiedErrorId -notmatch '^NoMatchingEventsFound') { throw }
    }
}

function Invoke-MigrationChildScript {
    param([string]$Path, [hashtable]$Arguments = @{})
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required script not found: $Path" }
    $engine = (Get-Process -Id $PID -ErrorAction Stop).Path
    # Windows PowerShell 5.1 -File cannot reliably transport explicit switch
    # booleans or array arguments. Serialize a splatted parameter dictionary instead.
    # Only base64 data is interpolated into the command; paths/values are never code.
    $invocation = @{ Path = (Get-Item -LiteralPath $Path).FullName; Arguments = $Arguments }
    $payload = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([Management.Automation.PSSerializer]::Serialize($invocation)))
    $command = @'
$ErrorActionPreference = 'Stop'
try {
    $invocation = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('__PAYLOAD__')))
    $parameters = $invocation.Arguments
    $global:LASTEXITCODE = 0
    & $invocation.Path @parameters
    exit ([int]$LASTEXITCODE)
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 99
}
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command.Replace('__PAYLOAD__', $payload)))
    & $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand $encoded | Out-Host
    return [int]$LASTEXITCODE
}

function Test-MigrationInstallerTrust {
    param([string]$Path, [string]$ExpectedSha256, [switch]$AllowUnsignedInstaller)
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($ExpectedSha256 -and $hash -ine $ExpectedSha256) { throw "Installer SHA-256 mismatch. Expected $ExpectedSha256, got $hash." }
    $signature = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
    if ($signature.Status -eq 'Valid') { return $hash }
    # Bundled VirtIO 0.1.271-1 was compared byte-for-byte with the project's archive on 2026-10-22:
    # https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.271-1/virtio-win-guest-tools.exe
    # Trust this exact published artifact without requiring operator flags. Never extend this to invalid signatures.
    $bundledSha256 = '21a2c7d7607ca52de3d7f57b57c8ba8752b9ba68ca89b54de48ff266091b14e4'
    if ($signature.Status -eq 'NotSigned' -and $hash -ieq $bundledSha256) { return $hash }
    # Other unsigned artifacts still require an explicit independently trusted hash and opt-in.
    if ($signature.Status -eq 'NotSigned' -and $AllowUnsignedInstaller -and $ExpectedSha256) { return $hash }
    throw "Installer signature is $($signature.Status). Unsigned installers require both -AllowUnsignedInstaller and a trusted -ExpectedInstallerSha256."
}

function Assert-MigrationArtifactPaths {
    param([string[]]$SourcePaths, [string[]]$DestinationPaths)
    foreach ($source in $SourcePaths) {
        $sourcePath = [IO.Path]::GetFullPath($source)
        foreach ($destination in $DestinationPaths) {
            if ([string]::Equals($sourcePath, [IO.Path]::GetFullPath($destination), [StringComparison]::OrdinalIgnoreCase)) {
                throw 'WorkingDirectory must not stage artifacts over the original source files. Select a separate working directory.'
            }
        }
    }
}
