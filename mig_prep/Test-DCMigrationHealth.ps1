#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only health check of Active Directory Domain Controllers before/after a
    VMware-to-Proxmox migration.

.DESCRIPTION
    Test-DCMigrationHealth.ps1 performs a fast, read-only assessment of one or more
    Domain Controllers covering reachability, core services, dcdiag, replication,
    DNS, SYSVOL/NETLOGON, FSMO/GC, time synchronisation and recent event log errors.

    Results are written to a timestamped report folder as text, CSV, JSON and a
    self-contained HTML report. When -CompareWith is supplied, the current run is
    compared against a previous JSON report to highlight regressions/improvements.

    The script makes NO changes to AD, DNS, replication, services, time
    configuration, the registry or event logs. It only reads/queries.

.PARAMETER Mode
    PreMigration or PostMigration. Used for labelling the report only.

.PARAMETER ComputerName
    Optional list of DC host names to test. If omitted, all writable
    (non-RODC) Domain Controllers in the current domain are discovered
    automatically.

.PARAMETER OutputPath
    Root folder for reports. Defaults to C:\DCHealth. A timestamped
    sub-folder is created for every run and is never overwritten.

.PARAMETER CompareWith
    Optional path to a previous Results.json file to compare against.

.EXAMPLE
    .\Test-DCMigrationHealth.ps1 -Mode PreMigration

.EXAMPLE
    .\Test-DCMigrationHealth.ps1 -Mode PostMigration -CompareWith "C:\DCHealth\2026-09-25_0937_PreMigration\Results.json"

.EXAMPLE
    .\Test-DCMigrationHealth.ps1 -Mode PreMigration -ComputerName DC01,DC02

.NOTES
    Exit codes: 0 = Healthy, 1 = Warning, 2 = Unhealthy, 3 = Script/prerequisite failure.
    Must be run elevated, on a DC or a management host with RSAT AD tools installed.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('PreMigration', 'PostMigration')]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = 'C:\DCHealth',

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
            throw "CompareWith file not found: $_"
        }
        $true
    })]
    [string]$CompareWith
)

# Read-only script: no AD/DNS/service/registry/eventlog writes are performed anywhere below.
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$Script:SchemaVersion = '1.1'
$Script:EventLogNames = @('Directory Service', 'DNS Server', 'DFS Replication', 'System')
$Script:CoreServiceNames = @('NTDS', 'DNS', 'Netlogon', 'DFSR', 'W32Time')
$Script:CriticalEventKeywords = @(
    'unable to.*(replicate|resolve|contact|start)', 'service could not be started',
    'not available', 'failed to load', 'disk (is|has) (full|corrupt|failing)',
    'no such object', 'sysvol.*(not|unavailable|share)', 'the network path was not found',
    'crashed', 'terminated unexpectedly', 'shutting down', 'jrnl_wrap', 'lingering object'
)
# dcdiag/w32tm text parsing below assumes en-US resource strings ('failed test', 'Source:', etc.).
# On a non-English OS these tools emit localized text, so parsing falls back to Warning instead of
# silently reporting Passed; Test-IsEnglishLocale lets the report surface that limitation once.
function Test-IsEnglishLocale {
    return ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'en')
}

#region Helper functions

function Test-IsAdministrator {
    <# Returns $true when the current process token has the local Administrator role. #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-CheckResult {
    <# Builds a standardized check-result object: Name / Status / Detail. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Passed', 'Warning', 'Failed', 'NotApplicable')][string]$Status,
        [Parameter(Mandatory = $false)][string]$Detail = ''
    )
    [PSCustomObject]@{
        Name   = $Name
        Status = $Status
        Detail = $Detail
    }
}

function Get-OverallStatusFromChecks {
    <# Rolls a list of check results up into a single Passed/Warning/Failed status. #>
    param([Parameter(Mandatory)][object[]]$Checks)
    $applicable = $Checks | Where-Object { $_.Status -ne 'NotApplicable' }
    if ($applicable | Where-Object { $_.Status -eq 'Failed' }) { return 'Failed' }
    if ($applicable | Where-Object { $_.Status -eq 'Warning' }) { return 'Warning' }
    return 'Passed'
}

function New-ReportFolder {
    <# Creates a unique, never-overwritten, timestamped report folder with a Raw subfolder. #>
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$Mode
    )
    if (-not (Test-Path -LiteralPath $BasePath)) {
        New-Item -Path $BasePath -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $folder = Join-Path -Path $BasePath -ChildPath "$($stamp)_$Mode"
    $final = $folder
    $suffix = 1
    while (Test-Path -LiteralPath $final) {
        $suffix++
        $final = "$($folder)_$suffix"
    }
    New-Item -Path $final -ItemType Directory -Force -ErrorAction Stop | Out-Null
    New-Item -Path (Join-Path $final 'Raw') -ItemType Directory -Force -ErrorAction Stop | Out-Null
    return $final
}

function Invoke-ExternalCommand {
    <# Runs an external console command with a hard timeout (default 90s) so an unresponsive DC
       cannot hang the whole run, and returns its combined stdout/stderr text without echoing to
       the host. On timeout the process is force-killed and any partial output is still returned. #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 90
    )
    $stdOutFile = [System.IO.Path]::GetTempFileName()
    $stdErrFile = [System.IO.Path]::GetTempFileName()
    $process = $null
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdOutFile -RedirectStandardError $stdErrFile -ErrorAction Stop
        $finished = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $finished) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
            $partial = ''
            if (Test-Path -LiteralPath $stdOutFile) { $partial = (Get-Content -LiteralPath $stdOutFile -Raw -ErrorAction SilentlyContinue) }
            return "$partial`r`nERROR: $FilePath timed out after $TimeoutSeconds second(s) and was terminated."
        }
        $stdOut = if (Test-Path -LiteralPath $stdOutFile) { Get-Content -LiteralPath $stdOutFile -Raw -ErrorAction SilentlyContinue } else { '' }
        $stdErr = if (Test-Path -LiteralPath $stdErrFile) { Get-Content -LiteralPath $stdErrFile -Raw -ErrorAction SilentlyContinue } else { '' }
        return "$stdOut$stdErr"
    }
    catch {
        return "ERROR invoking $($FilePath): $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $stdOutFile, $stdErrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-RemoteServiceStatus {
    <# Reads Win32_Service state via CIM (WSMan, falling back to DCOM), bounded by an explicit
       operation timeout so a non-responsive DC cannot hang the check. No changes are made. #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string[]]$ServiceNames,
        [Parameter(Mandatory = $false)][int]$OperationTimeoutSec = 20
    )
    $filter = ($ServiceNames | ForEach-Object { "Name='$_'" }) -join ' OR '
    try {
        return @(Get-CimInstance -ComputerName $ComputerName -ClassName Win32_Service -Filter $filter -OperationTimeoutSec $OperationTimeoutSec -ErrorAction Stop)
    }
    catch {
        try {
            $opt = New-CimSessionOption -Protocol Dcom
            $session = New-CimSession -ComputerName $ComputerName -SessionOption $opt -OperationTimeoutSec $OperationTimeoutSec -ErrorAction Stop
            try {
                return @(Get-CimInstance -CimSession $session -ClassName Win32_Service -Filter $filter -OperationTimeoutSec $OperationTimeoutSec -ErrorAction Stop)
            }
            finally {
                Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
            }
        }
        catch {
            throw "Unable to query services on $($ComputerName): $($_.Exception.Message)"
        }
    }
}

function ConvertFrom-DcDiagOutput {
    <# Parses raw dcdiag text into Passed/Failed plus the list of failed test names. dcdiag's
       'failed test'/'passed test' strings are localized on non-English OS builds; if neither
       marker is recognized at all, this reports Warning instead of silently assuming Passed. #>
    param([Parameter(Mandatory)][string]$RawOutput)
    $failedTests = @([regex]::Matches($RawOutput, '(?im)failed test\s+(\S+)') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($failedTests.Count -gt 0) {
        return New-CheckResult -Name 'DCDiag' -Status 'Failed' -Detail ("Failed test(s): {0}" -f ($failedTests -join ', '))
    }
    if ($RawOutput -notmatch '(?im)\bpassed test\b|\bfailed test\b') {
        return New-CheckResult -Name 'DCDiag' -Status 'Warning' -Detail 'dcdiag output did not contain recognizable en-US result markers (possible non-English OS locale or dcdiag failure); review the raw output'
    }
    return New-CheckResult -Name 'DCDiag' -Status 'Passed' -Detail 'No failed tests reported'
}

function ConvertFrom-DcDiagDnsOutput {
    <# Parses raw dcdiag /test:dns text into Passed/Warning/Failed. See ConvertFrom-DcDiagOutput
       for the same locale caveat; an unrecognized output format downgrades to Warning. #>
    param([Parameter(Mandatory)][string]$RawOutput)
    if ($RawOutput -match '(?im)^\s*Error(s)?:\s*\S') {
        $errLines = @([regex]::Matches($RawOutput, '(?im)^\s*Error.*$') | ForEach-Object { $_.Value.Trim() })
        return New-CheckResult -Name 'DNS (dcdiag)' -Status 'Failed' -Detail ($errLines -join '; ')
    }
    if ($RawOutput -match '(?im)^\s*Warning.*$') {
        $warnLines = @([regex]::Matches($RawOutput, '(?im)^\s*Warning.*$') | ForEach-Object { $_.Value.Trim() })
        return New-CheckResult -Name 'DNS (dcdiag)' -Status 'Warning' -Detail ($warnLines -join '; ')
    }
    if ($RawOutput -notmatch '(?im)\btest\b') {
        return New-CheckResult -Name 'DNS (dcdiag)' -Status 'Warning' -Detail 'dcdiag /test:dns output did not contain recognizable en-US result markers (possible non-English OS locale or dcdiag failure); review the raw output'
    }
    return New-CheckResult -Name 'DNS (dcdiag)' -Status 'Passed' -Detail 'No DNS errors reported by dcdiag'
}

function ConvertFrom-W32tmStatusOutput {
    <# Extracts the reported time Source from raw 'w32tm /query /status' text. #>
    param([Parameter(Mandatory)][string]$RawOutput)
    $match = [regex]::Match($RawOutput, '(?im)^Source:\s*(.+)$')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

function Test-EventTextSeverity {
    <# Heuristically classifies an event message as Failed-worthy vs plain Warning. #>
    param([Parameter(Mandatory)][string]$Message)
    foreach ($pattern in $Script:CriticalEventKeywords) {
        if ($Message -match $pattern) { return $true }
    }
    return $false
}

#endregion Helper functions

#region Per-DC check functions

function Test-DCReachability {
    <# DNS resolution + key port reachability. Returns the check result plus RPC(135)/SMB(445)/
       ADWS(9389) flags so callers can skip dcdiag/repadmin/w32tm/Get-WinEvent/AD-replication-cmdlet
       calls instead of letting them run into their own (much longer) connection timeouts. #>
    param([Parameter(Mandatory)][string]$DCName)
    try {
        Resolve-DnsName -Name $DCName -ErrorAction Stop | Out-Null
    }
    catch {
        return @{
            Result        = New-CheckResult -Name 'Reachability' -Status 'Failed' -Detail "DNS resolution failed: $($_.Exception.Message)"
            RpcAvailable  = $false
            AdwsAvailable = $false
            SmbAvailable  = $false
        }
    }
    $ldapOk = Test-NetConnection -ComputerName $DCName -Port 389 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $ldapOk) {
        return @{
            Result        = New-CheckResult -Name 'Reachability' -Status 'Failed' -Detail 'LDAP port 389 unreachable'
            RpcAvailable  = $false
            AdwsAvailable = $false
            SmbAvailable  = $false
        }
    }
    $rpcOk = [bool](Test-NetConnection -ComputerName $DCName -Port 135 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    $smbOk = [bool](Test-NetConnection -ComputerName $DCName -Port 445 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    $adwsOk = [bool](Test-NetConnection -ComputerName $DCName -Port 9389 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    return @{
        Result        = New-CheckResult -Name 'Reachability' -Status 'Passed' -Detail "DNS resolves and LDAP port 389 reachable (RPC 135: $rpcOk, SMB 445: $smbOk, ADWS 9389: $adwsOk)"
        RpcAvailable  = $rpcOk
        AdwsAvailable = $adwsOk
        SmbAvailable  = $smbOk
    }
}

function Test-CoreServiceHealth {
    <# Confirms NTDS/DNS/Netlogon/DFSR/W32Time are running via CIM (read-only, timeout-bounded).
       Returns the check result plus a Name->State map so callers (e.g. the time check) can
       inspect an individual service's state directly instead of text-matching the Detail string. #>
    param([Parameter(Mandatory)][string]$DCName)
    $stateMap = @{}
    try {
        $services = Get-RemoteServiceStatus -ComputerName $DCName -ServiceNames $Script:CoreServiceNames
    }
    catch {
        return @{
            Result        = New-CheckResult -Name 'Core Services' -Status 'Warning' -Detail "Could not query services: $($_.Exception.Message)"
            ServiceStates = $stateMap
        }
    }
    $notRunning = @()
    foreach ($svcName in $Script:CoreServiceNames) {
        $svc = $services | Where-Object { $_.Name -eq $svcName }
        $state = if ($svc) { $svc.State } else { 'NotFound' }
        $stateMap[$svcName] = $state
        if ($state -ne 'Running') {
            $notRunning += $svcName
        }
    }
    if ($notRunning.Count -gt 0) {
        return @{
            Result        = New-CheckResult -Name 'Core Services' -Status 'Failed' -Detail "Not running: $($notRunning -join ', ')"
            ServiceStates = $stateMap
        }
    }
    return @{
        Result        = New-CheckResult -Name 'Core Services' -Status 'Passed' -Detail 'NTDS, DNS, Netlogon, DFSR, W32Time all running'
        ServiceStates = $stateMap
    }
}

function Test-DcDiagGeneral {
    <# Runs a targeted (non-DNS) dcdiag pass against the DC and captures raw output (timeout-bounded). #>
    param(
        [Parameter(Mandatory)][string]$DCName,
        [Parameter(Mandatory)][string]$RawFolder
    )
    $raw = Invoke-ExternalCommand -FilePath 'dcdiag.exe' -ArgumentList @("/s:$DCName", '/skip:DNS') -TimeoutSeconds 150
    Set-Content -LiteralPath (Join-Path $RawFolder "dcdiag-$DCName.txt") -Value $raw -Encoding UTF8
    $result = ConvertFrom-DcDiagOutput -RawOutput $raw
    return @{ Result = $result; Raw = $raw }
}

function Test-DcDiagDns {
    <# Runs a targeted dcdiag DNS test against the DC and captures raw output (timeout-bounded). #>
    param(
        [Parameter(Mandatory)][string]$DCName,
        [Parameter(Mandatory)][string]$RawFolder
    )
    $raw = Invoke-ExternalCommand -FilePath 'dcdiag.exe' -ArgumentList @('/test:dns', "/s:$DCName") -TimeoutSeconds 90
    Set-Content -LiteralPath (Join-Path $RawFolder "dcdiag-dns-$DCName.txt") -Value $raw -Encoding UTF8
    $result = ConvertFrom-DcDiagDnsOutput -RawOutput $raw
    return @{ Result = $result; Raw = $raw }
}

function Test-DnsResolutionHealth {
    <# Verifies domain DNS resolution, key SRV records, and the DC hostname A/AAAA record. #>
    param(
        [Parameter(Mandatory)][string]$DCName,
        [Parameter(Mandatory)][string]$DomainDnsRoot
    )
    $issues = @()
    try {
        Resolve-DnsName -Name $DomainDnsRoot -ErrorAction Stop | Out-Null
    }
    catch {
        $issues += "Domain name '$DomainDnsRoot' did not resolve"
    }
    try {
        Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$DomainDnsRoot" -Type SRV -ErrorAction Stop | Out-Null
    }
    catch {
        $issues += "Missing SRV record _ldap._tcp.dc._msdcs.$DomainDnsRoot"
    }
    try {
        Resolve-DnsName -Name "_kerberos._tcp.$DomainDnsRoot" -Type SRV -ErrorAction Stop | Out-Null
    }
    catch {
        $issues += "Missing SRV record _kerberos._tcp.$DomainDnsRoot"
    }
    try {
        Resolve-DnsName -Name $DCName -ErrorAction Stop | Out-Null
    }
    catch {
        $issues += "DC hostname '$DCName' did not resolve to an IP address"
    }
    if ($issues.Count -gt 0) {
        return New-CheckResult -Name 'DNS Resolution' -Status 'Failed' -Detail ($issues -join '; ')
    }
    return New-CheckResult -Name 'DNS Resolution' -Status 'Passed' -Detail 'Domain, SRV records and DC hostname all resolve'
}

function Test-SysvolNetlogonShares {
    <# Confirms SYSVOL/NETLOGON shares exist (CIM, timeout-bounded). UNC accessibility is only
       tested when SMB (445) was confirmed reachable, since Test-Path over a blocked UNC path can
       take a long time to time out at the TCP layer. #>
    param(
        [Parameter(Mandatory)][string]$DCName,
        [Parameter(Mandatory)][bool]$SmbAvailable
    )
    $issues = @()
    try {
        $shares = @(Get-CimInstance -ComputerName $DCName -ClassName Win32_Share -OperationTimeoutSec 20 -ErrorAction Stop)
        foreach ($shareName in @('SYSVOL', 'NETLOGON')) {
            if (-not ($shares | Where-Object { $_.Name -eq $shareName })) {
                $issues += "$shareName share not found"
            }
        }
    }
    catch {
        $issues += "Could not enumerate shares: $($_.Exception.Message)"
    }
    if (-not $SmbAvailable) {
        $issues += 'SMB port 445 unreachable; UNC path accessibility was not tested'
        return New-CheckResult -Name 'SYSVOL/NETLOGON' -Status 'Warning' -Detail ($issues -join '; ')
    }
    foreach ($shareName in @('SYSVOL', 'NETLOGON')) {
        $unc = "\\$DCName\$shareName"
        if (-not (Test-Path -LiteralPath $unc -ErrorAction SilentlyContinue)) {
            $issues += "$unc not accessible"
        }
    }
    if ($issues.Count -gt 0) {
        return New-CheckResult -Name 'SYSVOL/NETLOGON' -Status 'Failed' -Detail ($issues -join '; ')
    }
    return New-CheckResult -Name 'SYSVOL/NETLOGON' -Status 'Passed' -Detail 'Both shares present and UNC paths accessible'
}

function Test-ReplicationHealth {
    <# Uses Get-ADReplicationPartnerMetadata/Failure (ADWS) for structured status; captures
       repadmin raw text separately over RPC. Callers must only invoke this when ADWS (9389) is
       reachable; repadmin capture is separately skipped by the caller when RPC (135) is down. #>
    param(
        [Parameter(Mandatory)][string]$DCName,
        [Parameter(Mandatory)][string]$RawFolder,
        [Parameter(Mandatory)][bool]$RpcAvailable
    )
    if ($RpcAvailable) {
        $raw = Invoke-ExternalCommand -FilePath 'repadmin.exe' -ArgumentList @('/showrepl', $DCName) -TimeoutSeconds 90
    }
    else {
        $raw = 'Skipped: RPC port 135 unreachable; repadmin /showrepl was not attempted.'
    }
    Set-Content -LiteralPath (Join-Path $RawFolder "repadmin-showrepl-$DCName.txt") -Value $raw -Encoding UTF8

    try {
        $partners = @(Get-ADReplicationPartnerMetadata -Target $DCName -Scope Server -PartnerType Both -ErrorAction Stop)
    }
    catch {
        return @{
            Result           = New-CheckResult -Name 'Replication' -Status 'Warning' -Detail "Could not query replication metadata: $($_.Exception.Message)"
            LargestDeltaMins = $null
            Raw              = $raw
        }
    }

    if ($partners.Count -eq 0) {
        # Single-DC (or isolated) domain: no partners is normal, not a failure.
        return @{
            Result           = New-CheckResult -Name 'Replication' -Status 'Passed' -Detail 'No replication partners (single-DC domain)'
            LargestDeltaMins = $null
            Raw              = $raw
        }
    }

    $now = Get-Date
    $deltas = @($partners | Where-Object { $_.LastReplicationSuccess } | ForEach-Object {
        [int]([Math]::Round(($now - $_.LastReplicationSuccess).TotalMinutes))
    })
    $largestDelta = if ($deltas.Count -gt 0) { ($deltas | Measure-Object -Maximum).Maximum } else { $null }

    $failures = @()
    try {
        $failures = @(Get-ADReplicationFailure -Target $DCName -Scope Server -ErrorAction Stop | Where-Object { $_.FailureCount -gt 0 })
    }
    catch {
        # Failure lookup is best-effort; absence of data is not itself a failure.
    }

    if ($failures.Count -gt 0) {
        $detail = ($failures | ForEach-Object { "$($_.Partner): $($_.FailureCount) failure(s), last error $($_.LastError)" }) -join '; '
        return @{
            Result           = New-CheckResult -Name 'Replication' -Status 'Failed' -Detail $detail
            LargestDeltaMins = $largestDelta
            Raw              = $raw
        }
    }
    if ($null -ne $largestDelta -and $largestDelta -gt 1440) {
        return @{
            Result           = New-CheckResult -Name 'Replication' -Status 'Warning' -Detail "No active failures, but largest replication delta is $largestDelta minutes"
            LargestDeltaMins = $largestDelta
            Raw              = $raw
        }
    }
    $deltaText = if ($null -ne $largestDelta) { "$largestDelta minute(s)" } else { 'N/A' }
    return @{
        Result           = New-CheckResult -Name 'Replication' -Status 'Passed' -Detail "No replication failures. Largest delta: $deltaText"
        LargestDeltaMins = $largestDelta
        Raw              = $raw
    }
}

function Test-TimeHealth {
    <# Records w32tm status/source (timeout-bounded) and evaluates the W32Time state using the
       actual service state (not a text match against another check's Detail string). #>
    param(
        [Parameter(Mandatory)][string]$DCName,
        [Parameter(Mandatory)][bool]$IsPdc,
        [Parameter(Mandatory)][string]$RawFolder,
        [Parameter(Mandatory = $false)][AllowNull()][string]$W32TimeState
    )
    $statusRaw = Invoke-ExternalCommand -FilePath 'w32tm.exe' -ArgumentList @('/query', '/status', "/computer:$DCName") -TimeoutSeconds 30
    $sourceRaw = Invoke-ExternalCommand -FilePath 'w32tm.exe' -ArgumentList @('/query', '/source', "/computer:$DCName") -TimeoutSeconds 30
    $combined = "=== /query /status ===`r`n$statusRaw`r`n=== /query /source ===`r`n$sourceRaw"
    Set-Content -LiteralPath (Join-Path $RawFolder "w32tm-$DCName.txt") -Value $combined -Encoding UTF8

    if ([string]::IsNullOrEmpty($W32TimeState)) {
        return New-CheckResult -Name 'Time Sync' -Status 'Warning' -Detail 'Unable to determine whether the W32Time service is running (service query failed)'
    }
    if ($W32TimeState -ne 'Running') {
        return New-CheckResult -Name 'Time Sync' -Status 'Failed' -Detail 'W32Time service is not running'
    }

    $source = ConvertFrom-W32tmStatusOutput -RawOutput $statusRaw
    if (-not $source) {
        $source = ($sourceRaw.Trim())
    }
    if ([string]::IsNullOrWhiteSpace($source) -or $source -match 'error|could not|unable') {
        return New-CheckResult -Name 'Time Sync' -Status 'Warning' -Detail 'Unable to determine time source'
    }
    $roleNote = if ($IsPdc) { ' (PDC Emulator)' } else { '' }
    # VM IC Time Synchronization Provider is a valid source and is not treated as an error.
    return New-CheckResult -Name 'Time Sync' -Status 'Passed' -Detail "Source$($roleNote): $source"
}

function Test-EventLogHealth {
    <# Reads new Critical/Error events (last 60 min) from key logs; classifies severity, exports raw
       CSV. Get-WinEvent -ComputerName uses RPC, so callers should only invoke this when RPC (135)
       was confirmed reachable. Get-WinEvent throws a terminating error both when a log has no
       matching events and when the log genuinely could not be queried; those two cases are
       distinguished below so a query failure is never silently reported as Passed. #>
    param(
        [Parameter(Mandatory)][string]$DCName,
        [Parameter(Mandatory)][string]$RawFolder
    )
    $since = (Get-Date).AddMinutes(-60)
    $allEvents = @()
    $failedLogs = @()
    foreach ($logName in $Script:EventLogNames) {
        try {
            $events = Get-WinEvent -ComputerName $DCName -FilterHashtable @{
                LogName   = $logName
                Level     = 1, 2
                StartTime = $since
            } -ErrorAction Stop -MaxEvents 200
            $allEvents += $events
        }
        catch {
            if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound' -or $_.Exception.Message -match 'No events were found') {
                # No matching events in this log is benign; not a query failure.
                continue
            }
            $failedLogs += "$($logName): $($_.Exception.Message)"
        }
    }

    $exportRows = @($allEvents | Sort-Object TimeCreated -Descending | ForEach-Object {
        [PSCustomObject]@{
            TimeCreated = $_.TimeCreated
            LogName     = $_.LogName
            Level       = $_.LevelDisplayName
            Id          = $_.Id
            Message     = ($_.Message -replace '\s+', ' ').Trim()
        }
    })
    $csvPath = Join-Path $RawFolder "events-$DCName.csv"
    if ($exportRows.Count -gt 0) {
        $exportRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    }
    elseif ($failedLogs.Count -gt 0) {
        Set-Content -LiteralPath $csvPath -Value "No events exported. Log(s) that could not be queried: $($failedLogs -join '; ')" -Encoding UTF8
    }
    else {
        Set-Content -LiteralPath $csvPath -Value 'No matching Critical/Error events in the last 60 minutes.' -Encoding UTF8
    }

    if ($failedLogs.Count -gt 0) {
        return New-CheckResult -Name 'Event Logs' -Status 'Warning' -Detail "Could not query $($failedLogs.Count) of $($Script:EventLogNames.Count) log(s): $($failedLogs -join '; ') ($($exportRows.Count) event(s) exported from the remaining log(s); see events-$DCName.csv)"
    }

    if ($exportRows.Count -eq 0) {
        return New-CheckResult -Name 'Event Logs' -Status 'Passed' -Detail 'No new Critical/Error events in the last 60 minutes'
    }
    $severe = @($exportRows | Where-Object { $_.Level -eq 'Critical' -or (Test-EventTextSeverity -Message $_.Message) })
    if ($severe.Count -gt 0) {
        return New-CheckResult -Name 'Event Logs' -Status 'Failed' -Detail "$($severe.Count) event(s) indicate a service outage (see events-$DCName.csv)"
    }
    return New-CheckResult -Name 'Event Logs' -Status 'Warning' -Detail "$($exportRows.Count) Error event(s) logged, none indicate an outage (see events-$DCName.csv)"
}

#endregion Per-DC check functions

function Invoke-DCHealthCheck {
    <# Orchestrates all checks for a single DC and returns its aggregated result object. RPC(135)/
       SMB(445)/ADWS(9389) reachability gates the checks that would otherwise run into their own,
       much longer, connection timeouts against an unresponsive DC. #>
    param(
        [Parameter(Mandatory)][object]$DCInfo,
        [Parameter(Mandatory)][string]$DomainDnsRoot,
        [Parameter(Mandatory)][string]$PdcEmulator,
        [Parameter(Mandatory)][string]$RawFolder
    )
    $dcName = $DCInfo.HostName
    Write-Host "Testing $dcName ..." -ForegroundColor Cyan

    $checks = @()
    $reachabilityInfo = Test-DCReachability -DCName $dcName
    $checks += $reachabilityInfo.Result

    if ($reachabilityInfo.Result.Status -eq 'Failed') {
        # DC unreachable: record as Failed and mark remaining checks NotApplicable, then move on.
        foreach ($name in 'Core Services', 'DCDiag', 'DNS (dcdiag)', 'DNS Resolution', 'SYSVOL/NETLOGON', 'Replication', 'Time Sync', 'Event Logs') {
            $checks += New-CheckResult -Name $name -Status 'NotApplicable' -Detail 'Skipped: DC unreachable'
        }
        return [PSCustomObject]@{
            ComputerName     = $dcName
            IsPDC            = ($dcName -eq $PdcEmulator)
            IsGlobalCatalog  = $DCInfo.IsGlobalCatalog
            FSMORoles        = @($DCInfo.OperationMasterRoles)
            LargestDeltaMins = $null
            OverallStatus    = 'Failed'
            Checks           = $checks
            RawOutputs       = [ordered]@{}
        }
    }

    $coreServices = Test-CoreServiceHealth -DCName $dcName
    $checks += $coreServices.Result

    if ($reachabilityInfo.RpcAvailable) {
        $dcDiag = Test-DcDiagGeneral -DCName $dcName -RawFolder $RawFolder
        $dcDiagDns = Test-DcDiagDns -DCName $dcName -RawFolder $RawFolder
    }
    else {
        $skipDetail = 'Skipped: RPC port 135 unreachable'
        Set-Content -LiteralPath (Join-Path $RawFolder "dcdiag-$dcName.txt") -Value $skipDetail -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $RawFolder "dcdiag-dns-$dcName.txt") -Value $skipDetail -Encoding UTF8
        $dcDiag = @{ Result = (New-CheckResult -Name 'DCDiag' -Status 'Warning' -Detail $skipDetail); Raw = $skipDetail }
        $dcDiagDns = @{ Result = (New-CheckResult -Name 'DNS (dcdiag)' -Status 'Warning' -Detail $skipDetail); Raw = $skipDetail }
    }
    $checks += $dcDiag.Result
    $checks += $dcDiagDns.Result

    $checks += Test-DnsResolutionHealth -DCName $dcName -DomainDnsRoot $DomainDnsRoot
    $checks += Test-SysvolNetlogonShares -DCName $dcName -SmbAvailable $reachabilityInfo.SmbAvailable

    if ($reachabilityInfo.AdwsAvailable) {
        $replication = Test-ReplicationHealth -DCName $dcName -RawFolder $RawFolder -RpcAvailable $reachabilityInfo.RpcAvailable
    }
    else {
        $skipDetail = 'Skipped: ADWS port 9389 unreachable; replication status unavailable from this host'
        Set-Content -LiteralPath (Join-Path $RawFolder "repadmin-showrepl-$dcName.txt") -Value $skipDetail -Encoding UTF8
        $replication = @{ Result = (New-CheckResult -Name 'Replication' -Status 'Warning' -Detail $skipDetail); LargestDeltaMins = $null; Raw = $skipDetail }
    }
    $checks += $replication.Result

    if ($reachabilityInfo.RpcAvailable) {
        $checks += Test-TimeHealth -DCName $dcName -IsPdc ($dcName -eq $PdcEmulator) -RawFolder $RawFolder -W32TimeState $coreServices.ServiceStates['W32Time']
        $checks += Test-EventLogHealth -DCName $dcName -RawFolder $RawFolder
    }
    else {
        $skipDetail = 'Skipped: RPC port 135 unreachable'
        Set-Content -LiteralPath (Join-Path $RawFolder "w32tm-$dcName.txt") -Value $skipDetail -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $RawFolder "events-$dcName.csv") -Value $skipDetail -Encoding UTF8
        $checks += New-CheckResult -Name 'Time Sync' -Status 'Warning' -Detail $skipDetail
        $checks += New-CheckResult -Name 'Event Logs' -Status 'Warning' -Detail $skipDetail
    }

    $overall = Get-OverallStatusFromChecks -Checks $checks

    $rawOutputs = [ordered]@{
        'DCDiag'            = $dcDiag.Raw
        'DCDiag DNS'        = $dcDiagDns.Raw
        'Repadmin Showrepl' = $replication.Raw
    }

    return [PSCustomObject]@{
        ComputerName     = $dcName
        IsPDC            = ($dcName -eq $PdcEmulator)
        IsGlobalCatalog  = $DCInfo.IsGlobalCatalog
        FSMORoles        = @($DCInfo.OperationMasterRoles)
        LargestDeltaMins = $replication.LargestDeltaMins
        OverallStatus    = $overall
        Checks           = $checks
        RawOutputs       = $rawOutputs
    }
}

function Resolve-TargetDomainControllers {
    <# Discovers writable DCs automatically, or resolves explicitly supplied names via AD. #>
    param([Parameter(Mandatory = $false)][string[]]$ComputerName)

    if ($ComputerName) {
        $results = @()
        foreach ($name in $ComputerName) {
            try {
                $dc = Get-ADDomainController -Identity $name -ErrorAction Stop
                $results += $dc
            }
            catch {
                Write-Warning "Could not query AD for '$name' (it may be unreachable): $($_.Exception.Message)"
                $results += [PSCustomObject]@{
                    HostName             = $name
                    IsGlobalCatalog      = $false
                    IsReadOnly           = $false
                    OperationMasterRoles = @()
                }
            }
        }
        return @($results)
    }

    # @() guards against Windows PowerShell 5.1 collapsing a single-DC-domain result (or a
    # single surviving DC after the RODC filter) from an array into a bare scalar, which would
    # otherwise break every downstream '.Count' check under Set-StrictMode.
    $all = @(Get-ADDomainController -Filter * -ErrorAction Stop)
    return @($all | Where-Object { -not $_.IsReadOnly })
}

function Compare-DCHealthReports {
    <# Compares a previous JSON report to the current in-memory report, per DC and per check. #>
    param(
        [Parameter(Mandatory)][object]$Previous,
        [Parameter(Mandatory)][object]$Current
    )
    if (-not $Previous.PSObject.Properties['SchemaVersion'] -or -not $Previous.PSObject.Properties['DomainControllers']) {
        Write-Warning "-CompareWith file does not look like a Results.json produced by this script (missing SchemaVersion/DomainControllers); comparison results may be empty or misleading."
    }
    elseif ([string]$Previous.SchemaVersion -ne $Script:SchemaVersion) {
        Write-Warning "-CompareWith file has SchemaVersion '$($Previous.SchemaVersion)' but this script produces '$($Script:SchemaVersion)'; comparison may be incomplete."
    }
    $comparisonRows = @()
    $prevDcs = @{}
    foreach ($dc in $Previous.DomainControllers) { $prevDcs[$dc.ComputerName] = $dc }
    $currDcs = @{}
    foreach ($dc in $Current.DomainControllers) { $currDcs[$dc.ComputerName] = $dc }

    foreach ($dcName in ($currDcs.Keys | Sort-Object)) {
        $curr = $currDcs[$dcName]
        if (-not $prevDcs.ContainsKey($dcName)) {
            $comparisonRows += [PSCustomObject]@{ ComputerName = $dcName; CheckName = '(DC)'; Previous = 'N/A'; Current = $curr.OverallStatus; Change = 'New DC' }
            continue
        }
        $prev = $prevDcs[$dcName]
        foreach ($currCheck in $curr.Checks) {
            $prevCheck = $prev.Checks | Where-Object { $_.Name -eq $currCheck.Name }
            $prevStatus = if ($prevCheck) { $prevCheck.Status } else { 'N/A' }
            $currStatus = $currCheck.Status
            $change = 'Unchanged'
            if ($prevStatus -eq $currStatus) {
                $change = 'Unchanged'
            }
            elseif ($currStatus -eq 'Passed' -and $prevStatus -in @('Failed', 'Warning')) {
                $change = 'Resolved'
            }
            elseif ($currStatus -eq 'Warning' -and $prevStatus -eq 'Failed') {
                $change = 'Improved'
            }
            elseif ($currStatus -eq 'Warning' -and $prevStatus -in @('Passed', 'NotApplicable', 'N/A')) {
                $change = 'New Warning'
            }
            elseif ($currStatus -eq 'Failed' -and $prevStatus -ne 'Failed') {
                $change = 'New Failure'
            }
            if ($change -ne 'Unchanged') {
                $comparisonRows += [PSCustomObject]@{
                    ComputerName = $dcName
                    CheckName    = $currCheck.Name
                    Previous     = $prevStatus
                    Current      = $currStatus
                    Change       = $change
                }
            }
        }
    }
    foreach ($dcName in ($prevDcs.Keys | Sort-Object)) {
        if (-not $currDcs.ContainsKey($dcName)) {
            $comparisonRows += [PSCustomObject]@{ ComputerName = $dcName; CheckName = '(DC)'; Previous = $prevDcs[$dcName].OverallStatus; Current = 'N/A'; Change = 'DC no longer present' }
        }
    }
    # @() guards against a single comparison row collapsing to a bare scalar on return.
    return @($comparisonRows)
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        'Passed' { '#2e7d32' }
        'Warning' { '#f9a825' }
        'Failed' { '#c62828' }
        default { '#757575' }
    }
}

function ConvertTo-HtmlEncoded {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function New-HtmlReport {
    <# Builds a single self-contained HTML report file from the in-memory report/comparison objects. #>
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory = $false)][object[]]$Comparison,
        [Parameter(Mandatory)][string]$OutFile
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<html><head><meta charset="utf-8"><title>DC Migration Health Report</title><style>')
    [void]$sb.Append('body{font-family:Segoe UI,Arial,sans-serif;margin:20px;background:#fafafa;color:#212121;}')
    [void]$sb.Append('h1,h2,h3{color:#1a237e;} table{border-collapse:collapse;width:100%;margin-bottom:20px;}')
    [void]$sb.Append('th,td{border:1px solid #ccc;padding:6px 10px;text-align:left;font-size:13px;} th{background:#e8eaf6;}')
    [void]$sb.Append('.badge{color:#fff;padding:2px 8px;border-radius:4px;font-weight:bold;font-size:12px;}')
    [void]$sb.Append('pre{background:#212121;color:#e0e0e0;padding:10px;overflow-x:auto;font-size:12px;max-height:400px;}')
    [void]$sb.Append('.section{margin-bottom:30px;}</style></head><body>')

    [void]$sb.Append("<h1>DC Migration Health Report</h1>")
    [void]$sb.Append("<div class='section'><table>")
    [void]$sb.Append("<tr><th>Mode</th><td>$(ConvertTo-HtmlEncoded $Report.Mode)</td></tr>")
    [void]$sb.Append("<tr><th>Execution Time</th><td>$(ConvertTo-HtmlEncoded $Report.Timestamp)</td></tr>")
    [void]$sb.Append("<tr><th>Domain</th><td>$(ConvertTo-HtmlEncoded $Report.Domain)</td></tr>")
    [void]$sb.Append("<tr><th>Forest</th><td>$(ConvertTo-HtmlEncoded $Report.Forest)</td></tr>")
    [void]$sb.Append("<tr><th>DCs Tested</th><td>$(ConvertTo-HtmlEncoded (($Report.DomainControllers | ForEach-Object ComputerName) -join ', '))</td></tr>")
    $overallColor = Get-StatusColor -Status $(if ($Report.OverallResult -eq 'Healthy') { 'Passed' } elseif ($Report.OverallResult -eq 'Warning') { 'Warning' } else { 'Failed' })
    [void]$sb.Append("<tr><th>Overall Result</th><td><span class='badge' style='background:$overallColor'>$(ConvertTo-HtmlEncoded $Report.OverallResult)</span></td></tr>")
    [void]$sb.Append("</table></div>")

    if ($Report.LocaleWarning) {
        [void]$sb.Append("<div class='section'><p><strong>Locale note:</strong> $(ConvertTo-HtmlEncoded $Report.LocaleWarning)</p></div>")
    }

    [void]$sb.Append("<div class='section'><h2>FSMO Role Holders</h2><table><tr><th>Role</th><th>Holder</th></tr>")
    foreach ($role in $Report.FSMORoles.Keys) {
        [void]$sb.Append("<tr><td>$(ConvertTo-HtmlEncoded $role)</td><td>$(ConvertTo-HtmlEncoded $Report.FSMORoles[$role])</td></tr>")
    }
    [void]$sb.Append('</table></div>')

    [void]$sb.Append("<div class='section'><h2>Per-DC Results</h2><table><tr><th>DC</th><th>PDC</th><th>GC</th><th>FSMO Roles</th><th>Overall</th></tr>")
    foreach ($dc in $Report.DomainControllers) {
        $color = Get-StatusColor -Status $dc.OverallStatus
        [void]$sb.Append("<tr><td>$(ConvertTo-HtmlEncoded $dc.ComputerName)</td><td>$($dc.IsPDC)</td><td>$($dc.IsGlobalCatalog)</td><td>$(ConvertTo-HtmlEncoded (($dc.FSMORoles) -join ', '))</td><td><span class='badge' style='background:$color'>$($dc.OverallStatus)</span></td></tr>")
    }
    [void]$sb.Append('</table></div>')

    foreach ($dc in $Report.DomainControllers) {
        [void]$sb.Append("<div class='section'><h3>$(ConvertTo-HtmlEncoded $dc.ComputerName) - Detailed Checks</h3><table><tr><th>Check</th><th>Status</th><th>Detail</th></tr>")
        foreach ($check in $dc.Checks) {
            $color = Get-StatusColor -Status $check.Status
            [void]$sb.Append("<tr><td>$(ConvertTo-HtmlEncoded $check.Name)</td><td><span class='badge' style='background:$color'>$($check.Status)</span></td><td>$(ConvertTo-HtmlEncoded $check.Detail)</td></tr>")
        }
        [void]$sb.Append('</table>')
        if ($null -ne $dc.LargestDeltaMins) {
            [void]$sb.Append("<p>Largest replication delta: $($dc.LargestDeltaMins) minute(s)</p>")
        }
        if ($dc.RawOutputs) {
            foreach ($rawKey in $dc.RawOutputs.Keys) {
                [void]$sb.Append("<h4>Raw: $(ConvertTo-HtmlEncoded $rawKey)</h4><pre>$(ConvertTo-HtmlEncoded $dc.RawOutputs[$rawKey])</pre>")
            }
        }
        [void]$sb.Append('</div>')
    }

    if ($Report.RepadminSummaryRaw) {
        [void]$sb.Append("<div class='section'><h2>repadmin /replsummary</h2><pre>$(ConvertTo-HtmlEncoded $Report.RepadminSummaryRaw)</pre></div>")
    }

    if ($Comparison -and $Comparison.Count -gt 0) {
        [void]$sb.Append("<div class='section'><h2>Pre/Post Comparison</h2><table><tr><th>DC</th><th>Check</th><th>Previous</th><th>Current</th><th>Change</th></tr>")
        foreach ($row in $Comparison) {
            [void]$sb.Append("<tr><td>$(ConvertTo-HtmlEncoded $row.ComputerName)</td><td>$(ConvertTo-HtmlEncoded $row.CheckName)</td><td>$(ConvertTo-HtmlEncoded $row.Previous)</td><td>$(ConvertTo-HtmlEncoded $row.Current)</td><td>$(ConvertTo-HtmlEncoded $row.Change)</td></tr>")
        }
        [void]$sb.Append('</table></div>')
    }

    [void]$sb.Append('</body></html>')
    Set-Content -LiteralPath $OutFile -Value $sb.ToString() -Encoding UTF8
}

function New-ComparisonHtmlReport {
    <# Writes a standalone Comparison.html summarizing pre/post differences. #>
    param(
        [Parameter(Mandatory)][object[]]$Comparison,
        [Parameter(Mandatory)][string]$OutFile
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<html><head><meta charset="utf-8"><title>DC Health Comparison</title><style>')
    [void]$sb.Append('body{font-family:Segoe UI,Arial,sans-serif;margin:20px;} table{border-collapse:collapse;width:100%;}')
    [void]$sb.Append('th,td{border:1px solid #ccc;padding:6px 10px;font-size:13px;} th{background:#e8eaf6;}</style></head><body>')
    [void]$sb.Append('<h1>Pre/Post Migration Comparison</h1><table><tr><th>DC</th><th>Check</th><th>Previous</th><th>Current</th><th>Change</th></tr>')
    foreach ($row in $Comparison) {
        [void]$sb.Append("<tr><td>$(ConvertTo-HtmlEncoded $row.ComputerName)</td><td>$(ConvertTo-HtmlEncoded $row.CheckName)</td><td>$(ConvertTo-HtmlEncoded $row.Previous)</td><td>$(ConvertTo-HtmlEncoded $row.Current)</td><td>$(ConvertTo-HtmlEncoded $row.Change)</td></tr>")
    }
    [void]$sb.Append('</table></body></html>')
    Set-Content -LiteralPath $OutFile -Value $sb.ToString() -Encoding UTF8
}

# ------------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------------
try {
    if (-not (Test-IsAdministrator)) {
        Write-Error 'This script must be run from an elevated (Administrator) PowerShell session.'
        exit 3
    }

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
    }
    catch {
        Write-Error "The ActiveDirectory module is required (install RSAT: Active Directory tools). $($_.Exception.Message)"
        exit 3
    }

    $startTime = Get-Date
    $reportFolder = New-ReportFolder -BasePath $OutputPath -Mode $Mode
    $rawFolder = Join-Path $reportFolder 'Raw'

    try {
        $domain = Get-ADDomain -ErrorAction Stop
        $forest = Get-ADForest -ErrorAction Stop
    }
    catch {
        Write-Error "Unable to query the current domain/forest: $($_.Exception.Message)"
        exit 3
    }

    $fsmoRoles = [ordered]@{
        PDCEmulator          = $domain.PDCEmulator
        RIDMaster            = $domain.RIDMaster
        InfrastructureMaster = $domain.InfrastructureMaster
        SchemaMaster         = $forest.SchemaMaster
        DomainNamingMaster   = $forest.DomainNamingMaster
    }

    try {
        $targetDCs = @(Resolve-TargetDomainControllers -ComputerName $ComputerName)
    }
    catch {
        Write-Error "Unable to discover Domain Controllers: $($_.Exception.Message)"
        exit 3
    }
    if ($targetDCs.Count -eq 0) {
        Write-Error 'No Domain Controllers found to test.'
        exit 3
    }

    $localeWarning = $null
    if (-not (Test-IsEnglishLocale)) {
        $localeWarning = "This host's UI culture is '$([System.Globalization.CultureInfo]::CurrentUICulture.Name)'. dcdiag/w32tm text parsing assumes English output; results for those checks may report Warning instead of a precise Pass/Fail. Review the raw output files if in doubt."
        Write-Warning $localeWarning
    }

    Write-Host 'DC Migration Health Check'
    Write-Host "Mode: $Mode"
    Write-Host "Domain: $($domain.DNSRoot)"
    Write-Host "DCs tested: $($targetDCs.Count)"
    Write-Host ''

    $repadminSummaryRaw = Invoke-ExternalCommand -FilePath 'repadmin.exe' -ArgumentList @('/replsummary') -TimeoutSeconds 90
    Set-Content -LiteralPath (Join-Path $rawFolder 'repadmin-summary.txt') -Value $repadminSummaryRaw -Encoding UTF8

    $dcResults = @()
    foreach ($dcInfo in $targetDCs) {
        try {
            $dcResult = Invoke-DCHealthCheck -DCInfo $dcInfo -DomainDnsRoot $domain.DNSRoot -PdcEmulator $domain.PDCEmulator -RawFolder $rawFolder
        }
        catch {
            # A coding/runtime error while testing one DC must not abort the remaining DCs.
            Write-Warning "Unexpected error while testing $($dcInfo.HostName): $($_.Exception.Message)"
            $dcResult = [PSCustomObject]@{
                ComputerName     = $dcInfo.HostName
                IsPDC            = ($dcInfo.HostName -eq $domain.PDCEmulator)
                IsGlobalCatalog  = $dcInfo.IsGlobalCatalog
                FSMORoles        = @($dcInfo.OperationMasterRoles)
                LargestDeltaMins = $null
                OverallStatus    = 'Failed'
                Checks           = @(New-CheckResult -Name 'Unexpected Error' -Status 'Failed' -Detail $_.Exception.Message)
                RawOutputs       = [ordered]@{}
            }
        }
        $dcResults += $dcResult
        $color = switch ($dcResult.OverallStatus) { 'Passed' { 'Green' } 'Warning' { 'Yellow' } default { 'Red' } }
        Write-Host ("{0,-15} {1}" -f $dcResult.ComputerName, $dcResult.OverallStatus.ToUpper()) -ForegroundColor $color
    }

    $allChecks = @($dcResults | ForEach-Object { $_.Checks })
    $passedCount = @($allChecks | Where-Object { $_.Status -eq 'Passed' }).Count
    $warningCount = @($allChecks | Where-Object { $_.Status -eq 'Warning' }).Count
    $failedCount = @($allChecks | Where-Object { $_.Status -eq 'Failed' }).Count

    if ($failedCount -gt 0) { $overallResult = 'Unhealthy' }
    elseif ($warningCount -gt 0) { $overallResult = 'Warning' }
    else { $overallResult = 'Healthy' }

    $report = [PSCustomObject]@{
        SchemaVersion       = $Script:SchemaVersion
        Mode                = $Mode
        Timestamp           = $startTime.ToString('yyyy-MM-dd HH:mm:ss')
        Domain              = $domain.DNSRoot
        Forest              = $forest.Name
        FSMORoles           = $fsmoRoles
        DomainControllers   = $dcResults
        OverallResult       = $overallResult
        Counts              = [ordered]@{ Passed = $passedCount; Warnings = $warningCount; Failed = $failedCount }
        RepadminSummaryRaw  = $repadminSummaryRaw
        LocaleWarning       = $localeWarning
    }

    # JSON export (used for future -CompareWith runs)
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $reportFolder 'Results.json') -Encoding UTF8

    # Summary.csv
    $csvRows = foreach ($dc in $dcResults) {
        foreach ($check in $dc.Checks) {
            [PSCustomObject]@{
                DomainController = $dc.ComputerName
                CheckName        = $check.Name
                Status           = $check.Status
                Detail           = $check.Detail
            }
        }
    }
    $csvRows | Export-Csv -LiteralPath (Join-Path $reportFolder 'Summary.csv') -NoTypeInformation -Encoding UTF8

    # Summary.txt (mirrors the console output)
    $summaryLines = @()
    $summaryLines += 'DC Migration Health Check'
    $summaryLines += "Mode: $Mode"
    $summaryLines += "Domain: $($domain.DNSRoot)"
    $summaryLines += "DCs tested: $($targetDCs.Count)"
    $summaryLines += ''
    foreach ($dc in $dcResults) { $summaryLines += ("{0,-15} {1}" -f $dc.ComputerName, $dc.OverallStatus.ToUpper()) }
    $summaryLines += ''
    $summaryLines += "Overall: $($overallResult.ToUpper())"
    $summaryLines += "Passed: $passedCount"
    $summaryLines += "Warnings: $warningCount"
    $summaryLines += "Failed: $failedCount"
    $failedChecks = foreach ($dc in $dcResults) { $dc.Checks | Where-Object { $_.Status -eq 'Failed' } | ForEach-Object { "- $($dc.ComputerName): $($_.Name) - $($_.Detail)" } }
    if ($failedChecks) {
        $summaryLines += ''
        $summaryLines += 'FAILED:'
        $summaryLines += $failedChecks
    }
    Set-Content -LiteralPath (Join-Path $reportFolder 'Summary.txt') -Value ($summaryLines -join "`r`n") -Encoding UTF8

    # Optional comparison against a previous run
    $comparisonRows = $null
    if ($CompareWith) {
        try {
            $previousReport = Get-Content -LiteralPath $CompareWith -Raw | ConvertFrom-Json
            $comparisonRows = @(Compare-DCHealthReports -Previous $previousReport -Current $report)
            if ($comparisonRows.Count -gt 0) {
                New-ComparisonHtmlReport -Comparison $comparisonRows -OutFile (Join-Path $reportFolder 'Comparison.html')
            }
        }
        catch {
            Write-Warning "Could not compare against '$CompareWith': $($_.Exception.Message)"
        }
    }

    New-HtmlReport -Report $report -Comparison $comparisonRows -OutFile (Join-Path $reportFolder 'FullReport.html')

    Write-Host ''
    Write-Host "Overall: $($overallResult.ToUpper())"
    Write-Host "Passed: $passedCount"
    Write-Host "Warnings: $warningCount"
    Write-Host "Failed: $failedCount"
    if ($failedChecks) {
        Write-Host ''
        Write-Host 'FAILED:' -ForegroundColor Red
        foreach ($line in $failedChecks) { Write-Host $line -ForegroundColor Red }
    }
    Write-Host ''
    Write-Host "Report: $(Join-Path $reportFolder 'FullReport.html')"

    switch ($overallResult) {
        'Healthy' { exit 0 }
        'Warning' { exit 1 }
        default { exit 2 }
    }
}
catch {
    Write-Error "Unexpected script failure: $($_.Exception.Message)"
    exit 3
}
