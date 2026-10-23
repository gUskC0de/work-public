#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:MigrationSourceRoot = $script:RepositoryRoot
$script:Failures = 0
$script:Passed = 0
$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('migration-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TempRoot | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern = '.')
    $caught = $false
    try { & $Action | Out-Null } catch { $caught = $true; if ($_.Exception.Message -notmatch $Pattern) { throw } }
    if (-not $caught) { throw "Expected an exception matching '$Pattern'." }
}
function Import-FunctionDefinitions {
    param([string]$FileName, [string[]]$Names = @())
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepositoryRoot $FileName), [ref]$tokens, [ref]$parseErrors)
    foreach ($definition in @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })) {
        if ($Names.Count -eq 0 -or $definition.Name -in $Names) {
            # Load functions only: no script setup, native commands or Windows mutations execute.
            Set-Item -Path "function:script:$($definition.Name)" -Value ([scriptblock]::Create($definition.Body.Extent.Text.Substring(1, $definition.Body.Extent.Text.Length - 2).Replace('$PSScriptRoot', '$script:MigrationSourceRoot')))
        }
    }
}
function Initialize-MultiNicFixture {
    $script:PreNetwork = [pscustomobject]@{ activeAdapters=@(
        [pscustomobject]@{interfaceAlias='SourcePrimary';interfaceIndex=18;macAddress='00-50-56-BD-54-B2'},
        [pscustomobject]@{interfaceAlias='SourceSecondary';interfaceIndex=28;macAddress='00-50-56-BD-1C-16'}
    ); ipv4Routes=@(
        [pscustomobject]@{interfaceIndex=28;destinationPrefix='192.0.2.0/24';nextHop='10.21.20.1';routeMetric=7;store='PersistentStore';protocol='NetMgmt';isPersistentOrStatic=$true;isConnectedRoute=$false;isDefaultRoute=$false}
    ) }
    # Enumeration order deliberately differs from the source. The secondary has no default gateway.
    $script:MappingTargets=@(
        [pscustomobject]@{isVirtIO=$true;adapter=[pscustomobject]@{interfaceAlias='TargetSecondary';interfaceIndex=8;macAddress='00:50:56:bd:1c:16';defaultGateways=@();status='Disabled'}},
        [pscustomobject]@{isVirtIO=$true;adapter=[pscustomobject]@{interfaceAlias='TargetPrimary';interfaceIndex=9;macAddress='005056BD54B2';defaultGateways=@('10.21.10.1');status='Up'}}
    )
}
function Get-PreparePhaseFixture {
    # Execute the real phase and its real parameter defaults with mocked child processes.
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:MigrationSourceRoot 'Migrate-VmwareToProxmox.ps1'),[ref]$tokens,[ref]$errors)
    $phaseSwitch=$ast.Find({ param($node) $node -is [Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text -eq '$Phase' }, $true)
    $clause=@($phaseSwitch.Clauses | Where-Object { $_.Item1.Value -eq 'Prepare' })[0].Item2.Extent.Text
    [scriptblock]::Create('[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="High")]' + $ast.ParamBlock.Extent.Text + $clause.Substring(1,$clause.Length-2))
}
function Invoke-BootPreparationFixture {
    param([int]$ExitCode=259, [string]$DriverName='vioscsi', [int]$Start=0, [int]$OverrideStart=0,
        [switch]$MissingPackage, [switch]$WrongPackage, [switch]$MissingBinary, [switch]$ProviderFailure,
        [switch]$MissingStart, [string]$PublishedInfName='oem14.inf')
    function Join-Path { param([string]$Path,[string]$ChildPath) "$Path/$ChildPath" }
    function Get-ItemProperty {
        param($LiteralPath)
        if ($LiteralPath -like '*StartOverride') { return [pscustomobject]@{'0'=$OverrideStart} }
        if ($MissingStart) { return [pscustomobject]@{} }
        [pscustomobject]@{Start=$Start}
    }
    function Test-Path { param($LiteralPath,$PathType) if ($LiteralPath -like '*StartOverride') { return $true }; return (-not $MissingBinary) }
    function Get-WindowsDriver {
        param([switch]$Online)
        if ($ProviderFailure) { throw 'Driver Store query failed' }
        if ($MissingPackage) { return @() }
        $inf=if ($WrongPackage) { 'unrelated.inf' } else { "$DriverName.inf" }
        [pscustomobject]@{Driver='oem14.inf';OriginalFileName="C:\Windows\System32\DriverStore\FileRepository\$inf"}
    }
    Assert-VirtioDriverPreparation -ExitCode $ExitCode -DriverName $DriverName -PublishedInfName $PublishedInfName
}
function Invoke-StorageHealthFixture {
    param([object[]]$Devices, [switch]$MetadataFailure, [switch]$EnumerationFailure)
    function Get-PnpDevice {
        param($Class,[switch]$PresentOnly)
        Assert-True ($Class -eq 'SCSIAdapter' -and $PresentOnly) 'The health query included absent/unrelated devices.'
        if ($EnumerationFailure) { throw 'PnP provider unavailable' }
        $Devices
    }
    function Get-PnpDeviceProperty {
        param($InstanceId,$KeyName)
        if ($MetadataFailure) { throw 'Device property query failed' }
        $device=@($Devices | Where-Object InstanceId -eq $InstanceId)[0]
        [pscustomobject]@{KeyName='DEVPKEY_Device_HardwareIds';Data=@(Get-MigrationProperty $device 'HardwareIds' @('PCI\VEN_1AF4&DEV_1004'))}
        [pscustomobject]@{KeyName='DEVPKEY_Device_ProblemCode';Data=(Get-MigrationProperty $device 'ProblemCode' 0)}
    }
    Test-StorageControllerHealth
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:Results = New-Object System.Collections.ArrayList
    $script:Actions = New-Object System.Collections.ArrayList
    $script:LogWriter = $null
    $script:RollbackCreated = $false
    $script:NetworkChanged = $false
    $script:PhaseExitCode = 0
    $script:PreNetwork = $null
    $script:PreState = $null
    $script:CurrentNetwork = $null
    $script:AdapterMappings = @()
    $script:AdapterMappingPath = ''
    $script:Capture = [pscustomobject]@{services=[pscustomobject]@{all=@([pscustomobject]@{name='VMTools';status='Running';startType='Auto'})}}
    # Intentional failure fixtures record structured results without printing misleading FAIL logs.
    function Write-Log { param([string]$Message, [ConsoleColor]$Color) }
    try { & $Body; $script:Passed++; Write-Host "PASS: $Name" }
    catch { $script:Failures++; Write-Host "FAIL: $Name -- $($_.Exception.Message) [line $($_.InvocationInfo.ScriptLineNumber)]" -ForegroundColor Red }
}

try {
    foreach ($file in @(Get-ChildItem $script:MigrationSourceRoot -Filter '*.ps1')) {
        $parseErrors = $null; $tokens = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "Parser errors in $($file.Name): $($parseErrors.Message -join '; ')" }
    }
    . (Join-Path $script:RepositoryRoot 'Migration.Common.ps1')
    Import-FunctionDefinitions 'load-virtio-scsi-on-boot.ps1' @('Assert-VirtioDriverPreparation')
    Import-FunctionDefinitions 'Restore-And-TestMigrationState.ps1'
    Import-FunctionDefinitions 'Export-MigrationState.ps1' @('Get-StructuredRoutes', 'Get-NetworkCapture', 'Disable-VMwareToolsServices')
    Import-FunctionDefinitions 'Migrate-VmwareToProxmox.ps1' @('Invoke-CheckedMigrationScript', 'Resolve-MigrationServerType', 'Write-MigrationCaptureSummary')
    $script:Mode = 'Full'

    Test-Case 'Firstboot requires evidence when no conversion is detected' {
        function Get-CimInstance { param($ClassName) @() }
        $path = Join-Path $script:TempRoot 'absent'
        $result = Get-MigrationFirstbootState -Path $path
        Assert-True ($result.state -eq 'NotDetected') 'Unexpected Firstboot state.'
        function Get-MigrationFirstbootState { [pscustomobject]@{ state='NotDetected' } }
        Assert-Throws { Assert-MigrationFirstbootComplete } 'cannot be established'
        Assert-True ((Assert-MigrationFirstbootComplete -FirstbootNotUsed).state -eq 'NotDetected') 'Explicit non-Firstboot mode rejected.'
    }
    Test-Case 'Legacy Firstboot completion log is accepted after the service is removed' {
        function Get-CimInstance { param($ClassName) @() }
        $path = Join-Path $script:TempRoot 'complete'
        New-Item -ItemType Directory -Path (Join-Path $path 'scripts') -Force | Out-Null
        'starting firstboot service', 'uninstalling firstboot service', 'Service uninstalled successfully' | Set-Content (Join-Path $path 'log.txt')
        Assert-True ((Get-MigrationFirstbootState -Path $path).state -eq 'Complete') 'Legacy completion was not recognized.'
    }
    Test-Case 'An active Firstboot service wins over a stale completion marker' {
        function Get-CimInstance { param($ClassName) [pscustomobject]@{ Name='firstboot'; PathName='firstboot.exe' } }
        $path = Join-Path $script:TempRoot 'complete'
        Set-Content (Join-Path $path 'complete') 'done'
        Assert-True ((Get-MigrationFirstbootState -Path $path).state -eq 'Pending') 'Active conversion was accepted.'
    }
    Test-Case 'Pending scripts and unknown state cannot be bypassed' {
        function Get-CimInstance { param($ClassName) @() }
        $path = Join-Path $script:TempRoot 'complete'
        Set-Content (Join-Path $path 'scripts/work.bat') 'echo work'
        Assert-True ((Get-MigrationFirstbootState -Path $path).state -eq 'Pending') 'Pending script was ignored.'
        function Get-MigrationFirstbootState { [pscustomobject]@{ state='Unknown'; pendingScripts=@() } }
        Assert-Throws { Assert-MigrationFirstbootComplete -FirstbootNotUsed } 'Unknown'
    }
    Test-Case 'Newest matching capture is selected across dates and suffixes' {
        $root = Join-Path $script:TempRoot 'captures'
        foreach ($item in @(@('2026-10-21','Export-MigrationState','2026-10-21T23:59:00Z'), @('2026-10-22','Export-MigrationState','2026-10-22T08:00:00Z'), @('2026-10-22','Export-MigrationState_0900_2','2026-10-22T09:00:00Z'))) {
            $path = Join-Path $root "Rutin_migration_$($item[0])/$($item[1])/State"
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            @{ capturedAtUtc=$item[2]; systemIdentity=@{ computerName='TEST01' } } | ConvertTo-Json | Set-Content (Join-Path $path 'PreMigrationState.json')
            '{}' | Set-Content (Join-Path $path 'NetworkConfiguration.json')
        }
        $selected = Resolve-MigrationStateDirectory -SearchRoot $root -ComputerName TEST01
        Assert-True ($selected -match 'Export-MigrationState_0900_2') 'Stale capture selected.'
        Remove-Item (Join-Path $selected 'NetworkConfiguration.json')
        Assert-Throws { Resolve-MigrationStateDirectory -SearchRoot $root -ComputerName TEST01 } 'Missing NetworkConfiguration'
    }
    Test-Case 'Capture discovery rejects a different computer' {
        Assert-Throws { Resolve-MigrationStateDirectory -SearchRoot (Join-Path $script:TempRoot 'captures') -ComputerName OTHER } 'No matching'
    }
    Test-Case 'Route classification uses Protocol and preserves persistent vs active routes' {
        function Get-NetAdapter { param($InterfaceIndex) [pscustomobject]@{ Name='Ethernet' } }
        function Get-NetRoute {
            param($AddressFamily,$PolicyStore)
            $one = [pscustomobject]@{ ifIndex=4; DestinationPrefix='10.2.0.0/16'; NextHop='10.1.0.2'; RouteMetric=7; Protocol='NetMgmt'; Publish='No' }
            if ($PolicyStore -eq 'PersistentStore') { $one }
            else { $one; [pscustomobject]@{ ifIndex=4; DestinationPrefix='10.3.0.0/16'; NextHop='0.0.0.0'; RouteMetric=9; Protocol='NetMgmt'; Publish='No' } }
        }
        $routes = @(Get-StructuredRoutes)
        Assert-True ($routes.Count -eq 2 -and $routes[0].isPersistentOrStatic) 'Static route classification failed.'
        Assert-True ($routes[0].store -eq 'PersistentStore' -and $routes[1].store -eq 'ActiveStore') 'Persistence was lost.'
        Assert-True ((Get-MigrationRouteProtocol ([pscustomobject]@{Protocol=2})) -eq 'Local') 'Numeric protocol was not handled.'
    }
    Test-Case 'Static routes use source NIC ownership, including on-link and non-default next hops' {
        $source = [pscustomobject]@{ interfaceIndex=4 }
        $mapping = [pscustomobject]@{ source=$source; target=[pscustomobject]@{adapter=[pscustomobject]@{interfaceIndex=20}} }
        $script:PreNetwork = [pscustomobject]@{ ipv4Routes=@(
            [pscustomobject]@{ interfaceIndex=4; destinationPrefix='10.2.0.0/16'; nextHop='10.1.0.2'; isPersistentOrStatic=$true; isConnectedRoute=$false; isDefaultRoute=$false },
            [pscustomobject]@{ interfaceIndex=4; destinationPrefix='10.3.0.0/16'; nextHop='0.0.0.0'; isPersistentOrStatic=$true; isConnectedRoute=$false; isDefaultRoute=$false },
            [pscustomobject]@{ interfaceIndex=5; destinationPrefix='10.4.0.0/16'; nextHop='10.1.0.3'; isPersistentOrStatic=$true; isConnectedRoute=$false; isDefaultRoute=$false }
        ) }
        $script:Restored = @()
        function Set-MigrationRoute { param($Route,$InterfaceIndex) $script:Restored += "$InterfaceIndex|$($Route.destinationPrefix)|$($Route.nextHop)" }
        Restore-StaticRoutes $mapping -Confirm:$false
        Assert-True ($script:Restored.Count -eq 2 -and $script:Restored[1] -eq '20|10.3.0.0/16|0.0.0.0') 'A valid route was skipped or assigned to the wrong NIC.'
    }
    Test-Case 'Disabled unique target is mapped; multi-NIC sources are never guessed' {
        function Find-VirtIOAdapters { [pscustomobject]@{ isVirtIO=$true; adapter=[pscustomobject]@{interfaceAlias='Ethernet 2';interfaceIndex=20;macAddress='020000000001';status='Disabled'} } }
        $script:PreNetwork = [pscustomobject]@{activeAdapters=@([pscustomobject]@{interfaceAlias='Old';interfaceIndex=4})}
        Assert-True ($null -ne (Resolve-AdapterMapping)) 'Disabled target was rejected.'
        $script:PreNetwork.activeAdapters += [pscustomobject]@{interfaceAlias='Other'}
        Assert-True ($null -eq (Resolve-AdapterMapping)) 'Multiple source adapters were guessed.'
    }
    Test-Case 'Network WhatIf never saves rollback or mutates the NIC/routes' {
        function Save-RollbackState { throw 'Unexpected rollback write' }
        function Restore-AdapterNetwork { throw 'Unexpected NIC mutation' }
        function Restore-StaticRoutes { throw 'Unexpected route mutation' }
        $mapping=[pscustomobject]@{target=[pscustomobject]@{adapter=[pscustomobject]@{interfaceAlias='Target'}}}
        Restore-Network $mapping -WhatIf
        Assert-True ($script:Actions[0].state -eq 'WHATIF') 'Preview was not recorded.'
    }
    Test-Case 'Tools WhatIf never invokes MSI or stops/deletes services' {
        function Get-VMwareToolsProducts { [pscustomobject]@{PSChildName='{11111111-1111-1111-1111-111111111111}'} }
        function Get-Service { param($Name) [pscustomobject]@{Name='VMTools'} }
        function Start-Process { throw 'Unexpected MSI invocation' }
        function Stop-Service { throw 'Unexpected service change' }
        Remove-VMwareToolsUninstall -WhatIf
        Assert-True ($script:Actions[0].state -eq 'WHATIF') 'Uninstall preview not recorded.'
    }
    Test-Case 'Failed MSI uninstall reports failure without destructive fallback' {
        function Get-VMwareToolsProducts { [pscustomobject]@{PSChildName='{11111111-1111-1111-1111-111111111111}'} }
        function Get-Service { param($Name) [pscustomobject]@{Name='VMTools'} }
        function Start-Process { param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru) [pscustomobject]@{ExitCode=1603} }
        function Remove-Item { throw 'Unexpected deletion' }
        $script:LogDirectory = $script:TempRoot
        Remove-VMwareToolsUninstall -Confirm:$false
        Assert-True ($script:Results[0].state -eq 'FAIL') 'MSI failure was not reported.'
    }
    Test-Case 'Network failure runs rollback and returns a blocking failure' {
        function Save-RollbackState { $script:RollbackCreated=$true }
        function Restore-AdapterNetwork { param($Mapping,[switch]$Confirm) throw 'Injected NIC failure' }
        function Restore-RollbackAdapter { param($Mapping,[switch]$Confirm) $script:RollbackRan=$true; return $true }
        $script:RollbackRan=$false
        $mapping=[pscustomobject]@{target=[pscustomobject]@{adapter=[pscustomobject]@{interfaceAlias='Target'}}}
        Assert-Throws { Restore-Network $mapping -Confirm:$false } 'RESTORE_FAILED_ROLLBACK_SAVED'
        Assert-True $script:RollbackRan 'Rollback was not attempted.'
    }
    Test-Case 'Rollback failure is distinguished from successful rollback' {
        function Save-RollbackState { $script:RollbackCreated=$true }
        function Restore-AdapterNetwork { param($Mapping,[switch]$Confirm) throw 'Injected NIC failure' }
        function Restore-RollbackAdapter { param($Mapping,[switch]$Confirm) throw 'Injected rollback failure' }
        $mapping=[pscustomobject]@{target=[pscustomobject]@{adapter=[pscustomobject]@{interfaceAlias='Target'}}}
        Assert-Throws { Restore-Network $mapping -Confirm:$false } 'RESTORE_FAILED_NO_ROLLBACK'
    }
    Test-Case 'Empty/single/multiple comparisons work and DNS ordering is preserved' {
        Compare-Values -Name 'empty' -Expected @() -Actual @()
        Compare-Values -Name 'single' -Expected @('a') -Actual @('a')
        Compare-Values -Name 'set' -Expected @('a','b') -Actual @('b','a') -Unordered
        Compare-Values -Name 'dns' -Expected @('a','b') -Actual @('b','a') -MismatchState FAIL
        Assert-True (@($script:Results | Where-Object state -eq PASS).Count -eq 3) 'Array comparisons failed.'
        Assert-True ($script:Results[3].state -eq 'FAIL') 'DNS priority difference was hidden.'
    }
    Test-Case 'Child failure stops the phase; accepted warnings propagate' {
        function Invoke-MigrationChildScript { param($Path,$Arguments) return 2 }
        Assert-Throws { Invoke-CheckedMigrationScript 'mig_prep.ps1' } 'phase was stopped'
        function Invoke-MigrationChildScript { param($Path,$Arguments) return 50 }
        Invoke-CheckedMigrationScript 'Export-MigrationState.ps1' -WarningCodes @(50)
        Assert-True ($script:PhaseExitCode -eq 1) 'Warning was lost.'
    }
    Test-Case 'Unsigned installer requires an explicit trusted hash; invalid signatures remain blocked' {
        function Get-FileHash { param($LiteralPath,$Algorithm) [pscustomobject]@{Hash='ABC'} }
        function Get-AuthenticodeSignature { param($FilePath) [pscustomobject]@{Status='NotSigned'} }
        Assert-Throws { Test-MigrationInstallerTrust -Path 'installer.exe' -AllowUnsignedInstaller } 'require both'
        Assert-Throws { Test-MigrationInstallerTrust -Path 'installer.exe' -ExpectedSha256 'WRONG' -AllowUnsignedInstaller } 'mismatch'
        Assert-True ((Test-MigrationInstallerTrust -Path 'installer.exe' -ExpectedSha256 ABC -AllowUnsignedInstaller) -eq 'ABC') 'Pinned unsigned installer rejected.'
        function Get-AuthenticodeSignature { param($FilePath) [pscustomobject]@{Status='HashMismatch'} }
        Assert-Throws { Test-MigrationInstallerTrust -Path 'installer.exe' -ExpectedSha256 ABC -AllowUnsignedInstaller } 'HashMismatch'
    }
    Test-Case 'Unavailable checks cannot yield a PASS summary' {
        Invoke-SafePart 'Injected check' { throw 'Unavailable' }
        Assert-True ((Get-Summary).overallStatus -eq 'WARNING') 'Unavailable check reported overall PASS.'
    }
    Test-Case 'Existing static IP gets its prefix corrected without being recreated' {
        $source = [pscustomobject]@{ dhcpEnabled=$false; ipv4Addresses=@([pscustomobject]@{address='192.0.2.10';prefixLength=24}); defaultGateways=@();interfaceIndex=4;interfaceMetric=10 }
        $target = [pscustomobject]@{ interfaceIndex=20;interfaceAlias='Target';status='Disabled' }
        $mapping = [pscustomobject]@{source=$source;target=[pscustomobject]@{adapter=$target}}
        $script:PreNetwork = [pscustomobject]@{ipv4Routes=@()}
        $script:Prefix=16; $script:Enabled=$false
        function Enable-NetAdapter { param($Name,$Confirm) $script:Enabled=$true }
        function Set-NetIPInterface { param($InterfaceIndex,$AddressFamily,$Dhcp,$InterfaceMetric,$Confirm) Assert-True ($AddressFamily -eq 'IPv4') 'IPv6 would have been changed.' }
        function Get-NetIPAddress { param($InterfaceIndex,$AddressFamily) [pscustomobject]@{IPAddress='192.0.2.10';PrefixLength=$script:Prefix;PrefixOrigin='Manual';AddressState='Preferred'} }
        function Set-NetIPAddress { param($InputObject,$PrefixLength,$Confirm) $script:Prefix=$PrefixLength }
        function New-NetIPAddress { throw 'Existing IP was unnecessarily recreated' }
        function Get-TargetStaticRoutes { param($InterfaceIndex) @() }
        function Set-CapturedDnsClient { param($Source,$InterfaceIndex) }
        function Get-NetAdapter { param($InterfaceIndex) [pscustomobject]@{Status='Up'} }
        Restore-AdapterNetwork $mapping -Confirm:$false
        Assert-True ($script:Prefix -eq 24 -and $script:Enabled -and $script:NetworkChanged) 'Prefix or adapter enable was not applied.'
    }
    Test-Case 'DNS automatic assignment resets servers and empty suffix is restored' {
        $source=[pscustomobject]@{dnsServers=@('192.0.2.53');dnsAutomatic=$true;dnsSuffix='';registerThisConnectionAddress=$false;useSuffixWhenRegistering=$false}
        function Get-DnsClientServerAddress { param($InterfaceIndex,$AddressFamily) Assert-True ($AddressFamily -eq 'IPv4') 'IPv6 DNS was queried for mutation.'; [pscustomobject]@{InterfaceIndex=$InterfaceIndex} }
        $script:DnsReset=$false; $script:SuffixRestored=$false
        function Set-DnsClientServerAddress { param($InputObject,$ServerAddresses,[switch]$ResetServerAddresses,$Confirm) $script:DnsReset=$ResetServerAddresses; Assert-True ($null -eq $ServerAddresses) 'DHCP DNS was pinned to a source lease.' }
        function Set-DnsClient { param($InterfaceIndex,$ConnectionSpecificSuffix,$RegisterThisConnectionsAddress,$UseSuffixWhenRegistering,$Confirm) $script:SuffixRestored=($ConnectionSpecificSuffix -eq '' -and -not $RegisterThisConnectionsAddress -and -not $UseSuffixWhenRegistering) }
        Set-CapturedDnsClient -Source $source -InterfaceIndex 20 -Confirm:$false
        Assert-True ($script:DnsReset -and $script:SuffixRestored) 'DNS assignment intent was not restored.'
    }
    Test-Case 'Rollback restores manual DNS on DHCP, suffix, routes and disabled state' {
        $source=[pscustomobject]@{dhcpEnabled=$true;interfaceMetric=17;status='Disabled';dnsAutomatic=$false;dnsServers=@('192.0.2.53');dnsSuffix='old.example';registerThisConnectionAddress=$true;useSuffixWhenRegistering=$true}
        $route=[pscustomobject]@{destinationPrefix='10.20.0.0/16';nextHop='192.0.2.1';routeMetric=7;store='ActiveStore'}
        function Get-DnsClientServerAddress { param($InterfaceIndex,$AddressFamily) [pscustomobject]@{InterfaceIndex=$InterfaceIndex} }
        $script:RollbackFixture=[pscustomobject]@{adapter=$source;routes=@($route)}
        $script:RollbackPath='mock.json';$script:RollbackDns=@();$script:Disabled=$false;$script:RouteStore='';$script:Dhcp=''
        function Read-JsonFile { param($Path) $script:RollbackFixture }
        function Enable-NetAdapter { param($Name,$Confirm) }
        function Get-TargetStaticRoutes { param($InterfaceIndex) @() }
        function Get-NetIPAddress { param($InterfaceIndex,$AddressFamily) @() }
        function Set-NetIPInterface { param($InterfaceIndex,$AddressFamily,$Dhcp,$InterfaceMetric,$Confirm) $script:Dhcp=$Dhcp }
        function Set-DnsClientServerAddress { param($InputObject,$ServerAddresses,$Confirm) $script:RollbackDns=@($ServerAddresses) }
        function Set-DnsClient { param($InterfaceIndex,$ConnectionSpecificSuffix,$RegisterThisConnectionsAddress,$UseSuffixWhenRegistering,$Confirm) Assert-True ($ConnectionSpecificSuffix -eq 'old.example') 'Rollback lost DNS suffix.' }
        function Set-MigrationRoute { param($Route,$InterfaceIndex) $script:RouteStore=$Route.store; Assert-True ($InterfaceIndex -eq 20) 'Rollback changed another NIC.' }
        function Disable-NetAdapter { param($Name,$Confirm) $script:Disabled=$true }
        $mapping=[pscustomobject]@{target=[pscustomobject]@{adapter=[pscustomobject]@{interfaceIndex=20;interfaceAlias='Target'}}}
        Assert-True (Restore-RollbackAdapter $mapping -Confirm:$false) 'Rollback did not return success.'
        Assert-True ($script:Dhcp -eq 'Enabled' -and $script:RollbackDns[0] -eq '192.0.2.53' -and $script:Disabled -and $script:RouteStore -eq 'ActiveStore') 'Rollback did not preserve the original configuration.'
    }
    Test-Case 'Active-only routes are not accidentally made persistent' {
        function Get-TargetStaticRoutes { param($InterfaceIndex) @() }
        $script:CreatedStore='';$script:CreatedIndex=0
        function New-NetRoute { param($DestinationPrefix,$NextHop,$InterfaceIndex,$RouteMetric,$AddressFamily,$Confirm,$PolicyStore) $script:CreatedStore=$PolicyStore;$script:CreatedIndex=$InterfaceIndex }
        Set-MigrationRoute -InterfaceIndex 20 -Confirm:$false -Route ([pscustomobject]@{destinationPrefix='10.20.0.0/16';nextHop='192.0.2.2';routeMetric=7;store='ActiveStore'})
        Assert-True ($script:CreatedStore -eq 'ActiveStore' -and $script:CreatedIndex -eq 20) 'Active-only route persistence changed.'
        Set-MigrationRoute -InterfaceIndex 20 -Confirm:$false -Route ([pscustomobject]@{destinationPrefix='10.21.0.0/16';nextHop='0.0.0.0';routeMetric=8;store='PersistentStore'})
        Assert-True ([string]::IsNullOrEmpty($script:CreatedStore)) 'Persistent route did not use the documented both-store default.'
    }
    Test-Case 'Missing route policy store blocks restoration instead of guessing' {
        Assert-Throws { Set-MigrationRoute -InterfaceIndex 20 -Confirm:$false -Route ([pscustomobject]@{destinationPrefix='10.0.0.0/8';nextHop='192.0.2.1';routeMetric=1;store=$null}) } 'policy store'
    }
    Test-Case 'A previously running trigger-start service is still compared' {
        $script:PreState=[pscustomobject]@{services=[pscustomobject]@{all=@([pscustomobject]@{name='PolicyAgent';startType='Auto';status='Running'},[pscustomobject]@{name='ExpectedStopped';startType='Auto';status='Stopped'})}}
        function Get-CimInstance { param($ClassName) @() }
        Compare-Services
        Assert-True ($script:Results[0].state -eq 'WARNING' -and $script:Results[0].details[0] -eq 'PolicyAgent') 'Critical stopped service was hidden or baseline stopped service was flagged.'
    }
    Test-Case 'Disabled VMware services report failure when the state change fails' {
        function Get-Service { param($Name) if ($Name -eq 'VMTools') { [pscustomobject]@{Name=$Name;Status='Running';StartType='Automatic'} } }
        function Stop-Service { param($Name,$Force) throw 'Access denied' }
        Assert-True (-not (Disable-VMwareToolsServices -Confirm:$false)) 'Failed service change reported success.'
        Assert-True ($script:Results[0].state -eq 'FAIL') 'Failed service change was not recorded.'
    }
    Test-Case 'WhatIf disk repair does not invoke Set-Disk or diskpart' {
        $script:RepairOfflineDisks=$true
        function Get-Disk { [pscustomobject]@{Number=1;FriendlyName='Data';Size=1GB;IsOffline=$true;IsReadOnly=$false} }
        function Set-Disk { throw 'Unexpected disk mutation' }
        function Invoke-DiskpartOnline { throw 'Unexpected native disk mutation' }
        Repair-OfflineDisks -WhatIf
        Assert-True ($script:Results[0].state -eq 'WARNING') 'Offline disk preview reported PASS.'
    }
    Test-Case 'Duplicate source disks cannot reuse one target size match' {
        $script:PreState=[pscustomobject]@{disks=@([pscustomobject]@{sizeBytes=10GB;partitionStyle='GPT'},[pscustomobject]@{sizeBytes=10GB;partitionStyle='GPT'})}
        function Get-Disk { [pscustomobject]@{Number=0;Size=10GB;PartitionStyle='GPT';IsOffline=$false;HealthStatus='Healthy'};[pscustomobject]@{Number=1;Size=20GB;PartitionStyle='GPT';IsOffline=$false;HealthStatus='Healthy'} }
        Compare-DiskState
        Assert-True (@($script:Results | Where-Object { $_.name -eq 'Disk layout' -and $_.state -eq 'FAIL' }).Count -eq 1) 'A missing source disk was hidden by reuse.'
    }
    Test-Case 'Actual child process preserves paths, spaced arguments and warning exit codes' {
        $path=Join-Path $script:TempRoot 'child with spaces.ps1'
        'param([string]$Value)', "if (`$Value -ne 'value with spaces') { exit 9 }", 'exit 50' | Set-Content -LiteralPath $path
        $code=Invoke-MigrationChildScript -Path $path -Arguments @{Value='value with spaces'}
        Assert-True ($code -eq 50) 'Child argument or exit-code isolation failed.'
    }
    Test-Case 'Automatic DC detection cannot be overridden as a normal server' {
        function Get-CimInstance { param($ClassName) [pscustomobject]@{DomainRole=5} }
        $ServerType='Auto'
        Assert-True ((Resolve-MigrationServerType) -eq 'DomainController') 'DC was not detected.'
        $ServerType='Normal'
        Assert-Throws { Resolve-MigrationServerType } 'conflicts'
    }
    Test-Case 'Read-only preview reports produce no files' {
        $WhatIfPreference=$true
        $ReportJsonPath=Join-Path $script:TempRoot 'must-not-exist.json'
        $summary=Write-Reports
        Assert-True (-not (Test-Path -LiteralPath $ReportJsonPath)) 'Preview wrote a report.'
        Assert-True ($summary.overallStatus -eq 'PASS') 'Unexpected preview summary.'
    }
    Test-Case 'Text HTML and JSON reports render captured array results' {
        $WhatIfPreference=$false
        $SchemaVersion='1.0';$StateDirectory='test-state';$Mode='ValidateOnly'
        $StateJsonPath='before.json';$PostStatePath='after.json';$RollbackPath='rollback.json'
        $ReportJsonPath=Join-Path $script:TempRoot 'report.json'
        $ReportHtmlPath=Join-Path $script:TempRoot 'report.html'
        $ReportTextPath=Join-Path $script:TempRoot 'report.txt'
        Add-Result 'Example check' 'PASS' 'Example result.' @('first detail','second detail')
        $summary=Write-Reports
        $json=Get-Content -LiteralPath $ReportJsonPath -Raw | ConvertFrom-Json
        Assert-True ($summary.overallStatus -eq 'PASS' -and @($json.results).Count -eq 1 -and $json.results[0].details.Count -eq 2) 'JSON report lost structured results.'
        Assert-True ((Test-Path $ReportHtmlPath) -and (Test-Path $ReportTextPath)) 'Human-readable reports were not written.'
    }
    Test-Case 'Unavailable route providers are not mistaken for an empty route set' {
        function Get-NetRoute { param($AddressFamily,$PolicyStore) throw 'Provider unavailable' }
        Assert-Throws { Get-MigrationNetRoutes } 'Provider unavailable'
    }
    Test-Case 'A single failed health check blocks a successful overall status' {
        Add-Result 'Healthy' 'PASS' 'Ready.'
        Add-Result 'Network' 'FAIL' 'Missing route.'
        Assert-True ((Get-Summary).overallStatus -eq 'FAIL') 'A blocking failure was hidden.'
    }
    Test-Case 'Child transport preserves explicit false switches and array parameters' {
        $path=Join-Path $script:TempRoot 'switch child.ps1'
        @(
            '[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="High")]',
            'param([switch]$Enabled,[string[]]$Items)',
            'if ($Enabled -or $Items.Count -ne 2 -or $Items[1] -ne ''literal $(not-a-command)'') { exit 9 }',
            'if (-not $PSCmdlet.ShouldProcess(''fixture'',''validate parameter transport'')) { exit 8 }',
            'exit 0'
        ) | Set-Content -LiteralPath $path
        $code=Invoke-MigrationChildScript -Path $path -Arguments @{ Enabled=$false; Confirm=$false; Items=@('one','literal $(not-a-command)') }
        Assert-True ($code -eq 0) 'Boolean/array parameters were changed or treated as executable code.'
    }
    Test-Case 'Artifact staging cannot overwrite and later delete original source files' {
        $source=Join-Path $script:TempRoot 'original.ps1'
        Assert-Throws { Assert-MigrationArtifactPaths -SourcePaths @($source) -DestinationPaths @($source) } 'original source files'
        Assert-MigrationArtifactPaths -SourcePaths @($source) -DestinationPaths @((Join-Path $script:TempRoot 'work/copy.ps1'))
    }
    Test-Case 'DNS registry lookup canonicalizes GUID braces and preserves assignment intent' {
        $script:ManualDns='192.0.2.53'
        function Get-ItemProperty {
            param($LiteralPath)
            Assert-True ($LiteralPath -match '\\Interfaces\\\{11111111-1111-1111-1111-111111111111\}$') 'Interface registry key was not brace-wrapped.'
            [pscustomobject]@{NameServer=$script:ManualDns}
        }
        Assert-True (-not (Get-MigrationAutomaticDns -InterfaceGuid ([guid]'11111111-1111-1111-1111-111111111111'))) 'Manual DNS was classified as automatic.'
        $script:ManualDns=''
        Assert-True (Get-MigrationAutomaticDns -InterfaceGuid '{11111111-1111-1111-1111-111111111111}') 'Automatic DNS was not recognized.'
    }
    Test-Case 'Prepare accepts a captured multi-NIC baseline with warnings and preserves its routes' {
        function Resolve-MigrationStateDirectory { return 'saved-state' }
        function Get-Content {
            param($LiteralPath, [switch]$Raw)
            '{"activeAdapters":[{"interfaceIndex":18},{"interfaceIndex":28}],"ipv4Routes":[{"interfaceIndex":28,"destinationPrefix":"10.50.0.0/16","nextHop":"10.21.20.1"}]}'
        }
        function Invoke-MigrationChildScript { throw 'Capture summary must not repeat driver or export operations' }
        Write-MigrationCaptureSummary
        Assert-True ($script:PhaseExitCode -eq 1) 'Multiple captured NICs must produce a warning, not block preparation or approve automatic mapping.'
    }
    Test-Case 'Prepare still rejects an empty adapter capture' {
        function Resolve-MigrationStateDirectory { return 'saved-state' }
        function Get-Content { param($LiteralPath, [switch]$Raw) '{"activeAdapters":[]}' }
        Assert-Throws { Write-MigrationCaptureSummary } 'no active adapters'
    }
    Test-Case 'Multi-NIC mapping follows normalized MACs rather than enumeration or gateways' {
        Initialize-MultiNicFixture
        function Find-VirtIOAdapters { $script:MappingTargets }
        $plan=@(Resolve-AdapterMapping)
        Assert-True ($plan.Count -eq 2 -and $plan[0].target.adapter.interfaceIndex -eq 9 -and $plan[1].target.adapter.interfaceIndex -eq 8) 'The NICs were swapped or a disabled secondary was rejected.'
        $script:Restored=@()
        function Set-MigrationRoute { param($Route,$InterfaceIndex) $script:Restored += "$InterfaceIndex|$($Route.destinationPrefix)|$($Route.nextHop)" }
        foreach ($entry in $plan) { Restore-StaticRoutes $entry -Confirm:$false }
        Assert-True ($script:Restored.Count -eq 1 -and $script:Restored[0] -eq '8|192.0.2.0/24|10.21.20.1') 'The secondary route did not follow its source NIC.'
    }
    Test-Case 'Explicit mapping restores both NIC identities when target MACs changed' {
        Initialize-MultiNicFixture
        $script:MappingTargets[0].adapter.macAddress='02-00-00-00-00-02'
        $script:MappingTargets[1].adapter.macAddress='02-00-00-00-00-01'
        function Find-VirtIOAdapters { $script:MappingTargets }
        $script:AdapterMappingPath=Join-Path $script:TempRoot 'adapter-map.json'
        '{"schemaVersion":"1.0","mappings":[{"sourceMacAddress":"005056BD1C16","targetMacAddress":"020000000002"},{"sourceMacAddress":"005056BD54B2","targetMacAddress":"020000000001"}]}' | Set-Content $script:AdapterMappingPath
        $plan=@(Resolve-AdapterMapping)
        Assert-True ($plan.Count -eq 2 -and $plan[0].target.adapter.interfaceIndex -eq 9 -and $plan[1].target.adapter.interfaceIndex -eq 8) 'Explicit source/target mapping was ignored.'
    }
    Test-Case 'Incomplete mapping returns no partial plan even when the first source matches' {
        Initialize-MultiNicFixture
        $script:MappingTargets[0].adapter.macAddress='020000000002'
        function Find-VirtIOAdapters { $script:MappingTargets }
        Assert-True ($null -eq (Resolve-AdapterMapping)) 'A partial plan escaped the resolver.'
        Assert-True (@($script:Results | Where-Object state -eq 'PASS').Count -eq 0) 'A partial plan was reported as approved.'
    }
    Test-Case 'Missing source MACs show an actionable diagnostic and both NIC inventories' {
        Initialize-MultiNicFixture
        $script:Mode='Full'
        $script:MappingTargets[0].adapter.macAddress='020000000002'
        function Find-VirtIOAdapters { $script:MappingTargets }
        Assert-True ($null -eq (Resolve-AdapterMapping)) 'Missing MAC produced a usable plan.'
        $report=$script:Results | ConvertTo-Json -Depth 8
        Assert-True ($report -match 'MIG-NET-001' -and $report -match 'old MAC may not have been copied' -and $report -match 'Captured source NICs' -and $report -match 'Detected target NICs' -and $report -match '020000000002' -and $report -match 'No network restoration was started') 'Missing-MAC guidance or inventory was omitted.'
    }
    Test-Case 'Duplicate source MACs or interface indexes block multi-NIC restoration' {
        Initialize-MultiNicFixture
        function Find-VirtIOAdapters { $script:MappingTargets }
        $script:PreNetwork.activeAdapters[1].macAddress=$script:PreNetwork.activeAdapters[0].macAddress
        Assert-True ($null -eq (Resolve-AdapterMapping)) 'Duplicate source MAC was accepted.'
        Initialize-MultiNicFixture
        $script:PreNetwork.activeAdapters[1].interfaceIndex=18
        Assert-True ($null -eq (Resolve-AdapterMapping)) 'Ambiguous source route ownership was accepted.'
    }
    Test-Case 'Explicit mapping cannot assign two source NICs to the same target' {
        Initialize-MultiNicFixture
        function Find-VirtIOAdapters { $script:MappingTargets }
        $script:AdapterMappingPath='fixture.json'
        function Read-JsonFile { param($Path) [pscustomobject]@{schemaVersion='1.0';mappings=@(
            [pscustomobject]@{sourceMacAddress='005056BD54B2';targetMacAddress='005056BD54B2'},
            [pscustomobject]@{sourceMacAddress='005056BD1C16';targetMacAddress='005056BD54B2'}
        )} }
        Assert-True ($null -eq (Resolve-AdapterMapping)) 'A target was reused.'
    }
    Test-Case 'Duplicate target MACs are rejected rather than selected by order' {
        Initialize-MultiNicFixture
        function Find-VirtIOAdapters { $script:MappingTargets }
        $script:MappingTargets += $script:MappingTargets[1]
        Assert-True ($null -eq (Resolve-AdapterMapping)) 'Duplicate target MACs were guessed.'
    }
    Test-Case 'Explicit mapping must cover all sources and belong to the captured computer' {
        Initialize-MultiNicFixture
        function Find-VirtIOAdapters { $script:MappingTargets }
        $script:AdapterMappingPath='fixture.json'
        function Read-JsonFile { param($Path) [pscustomobject]@{schemaVersion='1.0';mappings=@()} }
        Assert-True ($null -eq (Resolve-AdapterMapping)) 'An incomplete explicit mapping was accepted.'
        $script:PreState=[pscustomobject]@{systemIdentity=[pscustomobject]@{computerName='Expected'}}
        function Read-JsonFile { param($Path) [pscustomobject]@{schemaVersion='1.0';computerName='AnotherServer';mappings=@()} }
        Assert-True ($null -eq (Resolve-AdapterMapping)) 'A foreign mapping was accepted.'
    }
    Test-Case 'MAC validation rejects missing multicast and placeholder identities' {
        foreach ($mac in @('', '000000000000', 'FFFFFFFFFFFF', '01005E000001', 'invalid')) {
            Assert-Throws { ConvertTo-MigrationMacAddress $mac }
        }
        Assert-True ((ConvertTo-MigrationMacAddress '02:ab:cd:00:00:01') -eq '02ABCD000001') 'A valid local MAC was rejected.'
    }
    Test-Case 'Every target and route snapshot is written before network mutation' {
        Initialize-MultiNicFixture
        function Find-VirtIOAdapters { $script:MappingTargets }
        function Assert-MigrationTargetIdentity { param($Mapping) }
        function Get-TargetStaticRoutes { param($InterfaceIndex) [pscustomobject]@{interfaceIndex=$InterfaceIndex;destinationPrefix='198.51.100.0/24'} }
        $script:RollbackPath=Join-Path $script:TempRoot 'multi-rollback.json'
        Save-RollbackState @(Resolve-AdapterMapping)
        $saved=Get-Content -LiteralPath $script:RollbackPath -Raw | ConvertFrom-Json
        Assert-True ($script:RollbackCreated -and $saved.adapters.Count -eq 2 -and $saved.adapters[1].routes[0].interfaceIndex -eq 8) 'The complete baseline was not saved.'
    }
    Test-Case 'Failure capturing the second target blocks all network writes' {
        Initialize-MultiNicFixture
        function Find-VirtIOAdapters { $script:MappingTargets }
        function Assert-MigrationTargetIdentity { param($Mapping) }
        function Get-TargetStaticRoutes { param($InterfaceIndex) if ($InterfaceIndex -eq 8) { throw 'snapshot unavailable' }; @() }
        function Restore-AdapterNetwork { param($Mapping) throw 'Unexpected mutation' }
        $script:RollbackPath=Join-Path $script:TempRoot 'failed-multi-rollback.json'
        Assert-Throws { Restore-Network @(Resolve-AdapterMapping) -Confirm:$false } 'snapshot unavailable'
        Assert-True (-not $script:RollbackCreated -and -not (Test-Path $script:RollbackPath)) 'A partial baseline was published.'
    }
    Test-Case 'Failure applying the second NIC rolls back both attempted targets in reverse order' {
        Initialize-MultiNicFixture
        function Find-VirtIOAdapters { $script:MappingTargets }
        function Save-RollbackState { param($Mapping) Assert-True (@($Mapping).Count -eq 2) 'Snapshot plan is incomplete.' }
        $script:Sequence=@()
        function Restore-AdapterNetwork { param($Mapping) $script:Sequence += "apply:$($Mapping.target.adapter.interfaceIndex)"; if ($Mapping.target.adapter.interfaceIndex -eq 8) { throw 'secondary failed' } }
        function Restore-StaticRoutes { param($Mapping) }
        function Restore-RollbackAdapter { param($Mapping) $script:Sequence += "rollback:$($Mapping.target.adapter.interfaceIndex)"; return $true }
        Assert-Throws { Restore-Network @(Resolve-AdapterMapping) -Confirm:$false } '^RESTORE_FAILED_ROLLBACK_SAVED$'
        Assert-True (($script:Sequence -join ',') -eq 'apply:9,apply:8,rollback:8,rollback:9') 'Both targets were not rolled back in reverse order.'
    }
    Test-Case 'A failed secondary rollback does not prevent rollback of the primary' {
        Initialize-MultiNicFixture
        function Find-VirtIOAdapters { $script:MappingTargets }
        function Save-RollbackState { param($Mapping) }
        function Restore-AdapterNetwork { param($Mapping) if ($Mapping.target.adapter.interfaceIndex -eq 8) { throw 'secondary failed' } }
        function Restore-StaticRoutes { param($Mapping) }
        $script:PrimaryRecovered=$false
        function Restore-RollbackAdapter { param($Mapping) if ($Mapping.target.adapter.interfaceIndex -eq 8) { throw 'rollback failed' }; $script:PrimaryRecovered=$true; return $true }
        Assert-Throws { Restore-Network @(Resolve-AdapterMapping) -Confirm:$false } '^RESTORE_FAILED_NO_ROLLBACK$'
        Assert-True $script:PrimaryRecovered 'Primary rollback was skipped after secondary rollback failed.'
    }
    Test-Case 'Target identity changing after mapping blocks writes to a reused interface index' {
        Initialize-MultiNicFixture
        $mapping=[pscustomobject]@{target=$script:MappingTargets[0]}
        function Get-NetAdapter { param($InterfaceIndex) [pscustomobject]@{MacAddress='020000000099'} }
        Assert-Throws { Assert-MigrationTargetIdentity $mapping } 'changed identity'
    }
    Test-Case 'Multi-NIC WhatIf does not save snapshots or change either target' {
        Initialize-MultiNicFixture
        function Find-VirtIOAdapters { $script:MappingTargets }
        function Save-RollbackState { throw 'Unexpected write' }
        function Restore-AdapterNetwork { throw 'Unexpected mutation' }
        Restore-Network @(Resolve-AdapterMapping) -WhatIf
        Assert-True (@($script:Actions | Where-Object state -eq 'WHATIF').Count -eq 1) 'Preview was not reported.'
    }
    Test-Case 'Successful multi-NIC restoration applies both NICs and leaves an extra target unchanged' {
        Initialize-MultiNicFixture
        $script:MappingTargets += [pscustomobject]@{isVirtIO=$true;adapter=[pscustomobject]@{interfaceIndex=30;interfaceAlias='Unrelated';macAddress='020000000030'}}
        function Find-VirtIOAdapters { $script:MappingTargets }
        $script:Applied=@();$script:RouteTargets=@()
        function Save-RollbackState { param($Mapping) Assert-True (@($Mapping).Count -eq 2) 'The extra target entered the snapshot plan.' }
        function Restore-AdapterNetwork { param($Mapping) $script:Applied += $Mapping.target.adapter.interfaceIndex }
        function Set-MigrationRoute { param($Route,$InterfaceIndex) $script:RouteTargets += $InterfaceIndex }
        Restore-Network @(Resolve-AdapterMapping) -Confirm:$false
        Assert-True (($script:Applied -join ',') -eq '9,8' -and ($script:RouteTargets -join ',') -eq '8') 'The plan was incomplete or changed an unrelated target.'
    }
    Test-Case 'Failure restoring a secondary route rolls back both NICs' {
        Initialize-MultiNicFixture
        function Find-VirtIOAdapters { $script:MappingTargets }
        function Save-RollbackState { param($Mapping) }
        function Restore-AdapterNetwork { param($Mapping) }
        function Set-MigrationRoute { param($Route,$InterfaceIndex) throw 'Route rejected' }
        $script:Recovered=@()
        function Restore-RollbackAdapter { param($Mapping) $script:Recovered += $Mapping.target.adapter.interfaceIndex; return $true }
        Assert-Throws { Restore-Network @(Resolve-AdapterMapping) -Confirm:$false } '^RESTORE_FAILED_ROLLBACK_SAVED$'
        Assert-True (($script:Recovered -join ',') -eq '8,9') 'A route error did not roll back both NICs.'
    }
    Test-Case 'Multi-adapter rollback selects the secondary snapshot and its routes' {
        Initialize-MultiNicFixture
        $script:RollbackPath=Join-Path $script:TempRoot 'selected-rollback.json'
        $adapters=@(foreach ($target in $script:MappingTargets) {
            [pscustomobject]@{adapter=[pscustomobject]@{interfaceIndex=$target.adapter.interfaceIndex;dhcpEnabled=$true;interfaceMetric=$target.adapter.interfaceIndex;status='Up';dnsSuffix=$target.adapter.interfaceAlias};routes=@([pscustomobject]@{destinationPrefix='192.0.2.0/24';nextHop='10.21.20.1';routeMetric=7;store='PersistentStore'})}
        })
        [pscustomobject]@{schemaVersion='1.1';adapters=$adapters} | ConvertTo-Json -Depth 8 | Set-Content $script:RollbackPath
        function Assert-MigrationTargetIdentity { param($Mapping) }
        function Enable-NetAdapter { param($Name,$Confirm) }
        function Get-TargetStaticRoutes { param($InterfaceIndex) @() }
        function Get-NetIPAddress { param($InterfaceIndex,$AddressFamily) @() }
        function Set-NetIPInterface { param($InterfaceIndex,$AddressFamily,$Dhcp,$InterfaceMetric,$Confirm) Assert-True ($InterfaceIndex -eq 8 -and $InterfaceMetric -eq 8) 'Wrong adapter baseline selected.' }
        function Set-CapturedDnsClient { param($Source,$InterfaceIndex) Assert-True ($InterfaceIndex -eq 8 -and $Source.dnsSuffix -eq 'TargetSecondary') 'Wrong DNS baseline selected.' }
        $script:RecoveredRoute=$false
        function Set-MigrationRoute { param($Route,$InterfaceIndex) Assert-True ($InterfaceIndex -eq 8 -and $Route.nextHop -eq '10.21.20.1') 'Route restored to wrong NIC.'; $script:RecoveredRoute=$true }
        Assert-True (Restore-RollbackAdapter ([pscustomobject]@{target=$script:MappingTargets[0]}) -Confirm:$false) 'Rollback did not finish.'
        Assert-True $script:RecoveredRoute 'Secondary route snapshot was lost.'
    }
    Test-Case 'Post-comparison follows the approved mapping after both MACs change' {
        Initialize-MultiNicFixture
        $script:AdapterMappings=@()
        $current=@()
        for ($i=0; $i -lt 2; $i++) {
            $source=$script:PreNetwork.activeAdapters[$i]
            $target=$script:MappingTargets[1-$i].adapter
            foreach ($object in @($source,$target)) {
                $object | Add-Member NoteProperty dhcpEnabled $false
                $object | Add-Member NoteProperty ipv4Addresses @([pscustomobject]@{address="10.21.$(10+10*$i).$($i+15)";prefixLength=24})
                $object | Add-Member NoteProperty dnsAutomatic $true
                $object | Add-Member NoteProperty dnsServers @()
                $object | Add-Member NoteProperty dnsSuffix ''
                $object | Add-Member NoteProperty registerThisConnectionAddress $true
                $object | Add-Member NoteProperty useSuffixWhenRegistering $false
            }
            $source | Add-Member NoteProperty defaultGateways $target.defaultGateways
            $target.macAddress="02000000000$($i+1)"
            $script:AdapterMappings += [pscustomobject]@{source=$source;target=[pscustomobject]@{adapter=$target}}
            $current += $target
        }
        $script:CurrentNetwork=[pscustomobject]@{activeAdapters=$current}
        function Get-TargetStaticRoutes { param($InterfaceIndex) if ($InterfaceIndex -eq 8) { $script:PreNetwork.ipv4Routes[0] } }
        Compare-NetworkState
        Assert-True (@($script:Results | Where-Object state -eq 'FAIL').Count -eq 0) 'Comparison lost the explicit mapping or secondary route.'
    }
    Test-Case 'A missing planned target cannot be replaced by an IP-based comparison guess' {
        $source=[pscustomobject]@{interfaceIndex=18;interfaceAlias='Source';macAddress='005056000001';dhcpEnabled=$false;ipv4Addresses=@([pscustomobject]@{address='192.0.2.5'})}
        $script:PreNetwork=[pscustomobject]@{activeAdapters=@($source)}
        $script:AdapterMappings=@([pscustomobject]@{source=$source;target=[pscustomobject]@{adapter=[pscustomobject]@{interfaceIndex=9}}})
        $script:CurrentNetwork=[pscustomobject]@{activeAdapters=@([pscustomobject]@{interfaceIndex=8;macAddress='020000000002';ipv4Addresses=$source.ipv4Addresses})}
        Compare-NetworkState
        Assert-True (@($script:Results | Where-Object state -eq 'FAIL').Count -eq 1) 'A missing mapped NIC was accepted through a fallback.'
    }
    Test-Case 'The actual bundled unsigned installer is accepted without operator flags' {
        function Get-AuthenticodeSignature { param($FilePath) [pscustomobject]@{Status='NotSigned'} }
        $hash=Test-MigrationInstallerTrust -Path (Join-Path $script:MigrationSourceRoot 'virtio-win-guest-tools.exe')
        Assert-True ($hash -eq '21a2c7d7607ca52de3d7f57b57c8ba8752b9ba68ca89b54de48ff266091b14e4') 'The bundled artifact no longer matches the reviewed artifact.'
    }
    Test-Case 'An altered unsigned file is not authorized by the bundled artifact policy' {
        $path=Join-Path $script:TempRoot 'altered-installer.exe'
        'different bytes' | Set-Content $path
        function Get-AuthenticodeSignature { param($FilePath) [pscustomobject]@{Status='NotSigned'} }
        Assert-Throws { Test-MigrationInstallerTrust -Path $path } 'require both'
    }
    Test-Case 'Bundled artifact policy cannot bypass an invalid signature or explicit hash mismatch' {
        function Get-FileHash { param($LiteralPath,$Algorithm) [pscustomobject]@{Hash='21a2c7d7607ca52de3d7f57b57c8ba8752b9ba68ca89b54de48ff266091b14e4'} }
        function Get-AuthenticodeSignature { param($FilePath) [pscustomobject]@{Status='HashMismatch'} }
        Assert-Throws { Test-MigrationInstallerTrust -Path 'fixture.exe' } 'HashMismatch'
        Assert-Throws { Test-MigrationInstallerTrust -Path 'fixture.exe' -ExpectedSha256 'WRONG' } 'SHA-256 mismatch'
    }
    Test-Case 'Normal Prepare captures and disables Tools by default without installer override flags' {
        $script:PrepareCalls=@()
        function Invoke-CheckedMigrationScript { param($Name,$Arguments,$WarningCodes) $script:PrepareCalls += [pscustomobject]@{name=$Name;arguments=$Arguments} }
        function Write-MigrationCaptureSummary { }
        & (Get-PreparePhaseFixture) -Confirm:$false
        Assert-True ($script:PrepareCalls.Count -eq 2 -and $script:PrepareCalls[0].name -eq 'mig_prep.ps1' -and $script:PrepareCalls[0].arguments.Count -eq 0) 'Prepare unexpectedly required installer overrides.'
        Assert-True ($script:PrepareCalls[1].name -eq 'Export-MigrationState.ps1' -and $script:PrepareCalls[1].arguments.DisableVMwareTools -and -not $script:PrepareCalls[1].arguments.Confirm) 'The original source service workflow was not retained.'
    }
    Test-Case 'Prepare still supports keeping VMware services unchanged explicitly' {
        $script:PrepareCalls=@()
        function Invoke-CheckedMigrationScript { param($Name,$Arguments,$WarningCodes) $script:PrepareCalls += [pscustomobject]@{name=$Name;arguments=$Arguments} }
        function Write-MigrationCaptureSummary { }
        & (Get-PreparePhaseFixture) -DisableVMwareTools:$false -Confirm:$false
        Assert-True (-not $script:PrepareCalls[1].arguments.ContainsKey('DisableVMwareTools')) 'The explicit opt-out was ignored.'
    }
    Test-Case 'Prepare preview launches no child process or source service change' {
        function Invoke-CheckedMigrationScript { throw 'Unexpected mutation' }
        function Write-MigrationCaptureSummary { throw 'Unexpected capture' }
        & (Get-PreparePhaseFixture) -WhatIf
    }
    Test-Case 'Tools shutdown preserves registration and verifies the reversible service state' {
        $script:ToolsStopped=$false;$script:ToolsDisabled=$false
        function Get-Service { param($Name) if ($Name -eq 'VMTools') { [pscustomobject]@{Name=$Name;Status=$(if ($script:ToolsStopped) {'Stopped'} else {'Running'});StartType=$(if ($script:ToolsDisabled) {'Disabled'} else {'Automatic'})} } }
        function Stop-Service { param($Name,$Force) $script:ToolsStopped=$true }
        function Set-Service { param($Name,$StartupType) Assert-True ($StartupType -eq 'Disabled') 'Wrong service startup state.'; $script:ToolsDisabled=$true }
        Assert-True (Disable-VMwareToolsServices -Confirm:$false) 'Reversible shutdown failed.'
        Assert-True ($script:ToolsStopped -and $script:ToolsDisabled -and $script:Capture.services.all[0].startType -eq 'Auto') 'Original service state was lost.'
    }
    Test-Case 'Tools shutdown refuses source mutation without the original service baseline' {
        $script:Capture=[pscustomobject]@{services=[pscustomobject]@{all=@()}}
        function Stop-Service { throw 'Unexpected mutation' }
        function Set-Service { throw 'Unexpected mutation' }
        Assert-True (-not (Disable-VMwareToolsServices -Confirm:$false)) 'Missing service baseline did not block mutation.'
    }
    Test-Case 'PnPUtil 259 is accepted after package binary and boot-start verification for SCSI and Block' {
        Invoke-BootPreparationFixture
        Invoke-BootPreparationFixture -DriverName viostor
    }
    Test-Case 'PnPUtil 259 cannot hide a missing or wrong Driver Store package' {
        Assert-Throws { Invoke-BootPreparationFixture -MissingPackage } 'does not uniquely identify'
        Assert-Throws { Invoke-BootPreparationFixture -WrongPackage } 'does not uniquely identify'
        Assert-Throws { Invoke-BootPreparationFixture -PublishedInfName 'unknown.inf' } 'Cannot verify'
    }
    Test-Case 'PnPUtil 259 cannot hide a failed package query or missing boot binary' {
        Assert-Throws { Invoke-BootPreparationFixture -ProviderFailure } 'Driver Store query failed'
        Assert-Throws { Invoke-BootPreparationFixture -MissingBinary } 'Boot driver binary is missing'
    }
    Test-Case 'Missing or disabled boot-start settings block preparation despite PnPUtil 259' {
        Assert-Throws { Invoke-BootPreparationFixture -Start 3 } 'not configured as a boot-start'
        Assert-Throws { Invoke-BootPreparationFixture -MissingStart } 'not configured as a boot-start'
        Assert-Throws { Invoke-BootPreparationFixture -OverrideStart 3 } 'non-boot StartOverride'
    }
    Test-Case 'Real PnPUtil errors remain blocking and success paths keep their boot checks' {
        Assert-Throws { Invoke-BootPreparationFixture -ExitCode 5 } 'pnputil exit code 5'
        Invoke-BootPreparationFixture -ExitCode 0 -ProviderFailure
        Invoke-BootPreparationFixture -ExitCode 3010 -ProviderFailure
        Assert-Throws { Invoke-BootPreparationFixture -ExitCode 0 -Start 3 } 'boot-start'
        Assert-Throws { Invoke-BootPreparationFixture -ExitCode 3010 -OverrideStart 3 } 'StartOverride'
    }
    Test-Case 'A route export failure preserves both NICs but explicitly blocks restoration' {
        Initialize-MultiNicFixture
        $script:SchemaVersion='1.0';$script:IpConfigPath='ipconfig.txt';$script:RoutePath='routes.txt';$script:ArpPath='arp.txt'
        function Get-ActiveAdapters { $script:PreNetwork.activeAdapters }
        function Get-StructuredRoutes { throw 'A route has no Protocol property' }
        $network=Get-NetworkCapture
        Assert-True ($network.activeAdapters.Count -eq 2 -and -not $network.routeCaptureComplete -and $network.ipv4Routes.Count -eq 0) 'Route failure discarded NICs or appeared complete.'
        Assert-Throws { Assert-MigrationNetworkCaptureComplete $network } 'route capture is incomplete'
        Assert-True (@($script:Results | Where-Object state -eq 'FAIL').Count -eq 1) 'Route failure was treated as non-critical.'
    }
    Test-Case 'A complete network export distinguishes no static routes from missing route data' {
        Assert-MigrationNetworkCaptureComplete ([pscustomobject]@{activeAdapters=@([pscustomobject]@{interfaceIndex=18});ipv4Routes=@()})
        Assert-MigrationNetworkCaptureComplete ([ordered]@{activeAdapters=@([pscustomobject]@{interfaceIndex=18});ipv4Routes=@();routeCaptureComplete=$true})
        Assert-Throws { Assert-MigrationNetworkCaptureComplete ([pscustomobject]@{activeAdapters=@([pscustomobject]@{interfaceIndex=18})}) } 'missing ipv4Routes'
        Assert-Throws { Assert-MigrationNetworkCaptureComplete ([ordered]@{activeAdapters=@([pscustomobject]@{interfaceIndex=18});ipv4Routes=$null}) } 'missing ipv4Routes'
    }
    Test-Case 'Prepare reports an incomplete network capture without an activeAdapters property exception' {
        function Resolve-MigrationStateDirectory { 'saved-state' }
        function Get-Content { param($LiteralPath,[switch]$Raw) '{}' }
        Assert-Throws { Write-MigrationCaptureSummary } 'Network capture contains no active adapters'
        function Get-Content { param($LiteralPath,[switch]$Raw) '{"activeAdapters":[{"interfaceIndex":18}],"ipv4Routes":[],"routeCaptureComplete":false}' }
        Assert-Throws { Write-MigrationCaptureSummary } 'route capture is incomplete'
    }
    Test-Case 'Server 2019 persistent routes with null or 65535 Protocol keep persistence and ownership' {
        function Get-NetAdapter { param($InterfaceIndex) [pscustomobject]@{Name="NIC$InterfaceIndex"} }
        function Get-NetRoute {
            param($AddressFamily,$PolicyStore)
            if ($PolicyStore -eq 'PersistentStore') {
                [pscustomobject]@{ifIndex=28;DestinationPrefix='10.100.1.110/32';NextHop='10.21.20.65';RouteMetric=7;Protocol=$null}
                [pscustomobject]@{ifIndex=18;DestinationPrefix='0.0.0.0/0';NextHop='10.21.10.1';RouteMetric=256;Protocol=65535}
                [pscustomobject]@{ifIndex=14;DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=50;Protocol=$null}
            } else {
                [pscustomobject]@{ifIndex=28;DestinationPrefix='10.100.1.110/32';NextHop='10.21.20.65';RouteMetric=7;Protocol='NetMgmt'}
                [pscustomobject]@{ifIndex=18;DestinationPrefix='0.0.0.0/0';NextHop='10.21.10.1';RouteMetric=256;Protocol='NetMgmt'}
                [pscustomobject]@{ifIndex=28;DestinationPrefix='10.21.20.64/28';NextHop='0.0.0.0';RouteMetric=256;Protocol='Local'}
            }
        }
        $routes=@(Get-StructuredRoutes)
        Assert-True ($routes.Count -eq 4) 'Persistent-only route or deduplicated active routes were lost.'
        $saved=@($routes | Where-Object store -eq 'PersistentStore')
        Assert-True ($saved.Count -eq 3 -and @($saved | Where-Object { -not $_.isPersistentOrStatic }).Count -eq 0) 'Saved routes with unknown native protocol were misclassified.'
        Assert-True (@($saved | Where-Object { $_.interfaceIndex -eq 14 -and $_.protocolSource -eq 'PersistentStore' }).Count -eq 1) 'Inactive interface ownership or classification provenance was lost.'
        $script:PreNetwork=[pscustomobject]@{ipv4Routes=$routes};$script:Restored=@()
        function Set-MigrationRoute { param($Route,$InterfaceIndex) $script:Restored += "$InterfaceIndex|$($Route.destinationPrefix)" }
        Restore-StaticRoutes ([pscustomobject]@{source=[pscustomobject]@{interfaceIndex=28};target=[pscustomobject]@{adapter=[pscustomobject]@{interfaceIndex=8}}}) -Confirm:$false
        Assert-True (($script:Restored -join ',') -eq '8|10.100.1.110/32') 'Uncaptured interface route was moved or the secondary route was lost.'
    }
    Test-Case 'PersistentStore alone supplies safe classification but unclassified active-only routes remain blocked' {
        foreach ($value in @($null,'',65535,'Unknown')) {
            $route=[pscustomobject]@{Protocol=$value}
            Assert-True ((Get-MigrationRouteProtocol $route -PolicyStore PersistentStore) -eq 'NetMgmt') 'Persistent classification failed.'
            Assert-Throws { Get-MigrationRouteProtocol $route } 'no usable Protocol'
        }
        Assert-True ((Get-MigrationRouteProtocol ([pscustomobject]@{Protocol='Local'}) -PolicyStore PersistentStore) -eq 'Local') 'A known connected route became static.'
    }
    Test-Case 'Target snapshot includes persistent-only routes with unspecified native protocol' {
        function Get-NetRoute {
            param($AddressFamily,$PolicyStore,$InterfaceIndex)
            if ($PolicyStore -eq 'PersistentStore') {
                [pscustomobject]@{DestinationPrefix='198.51.100.0/24';NextHop='10.21.20.65';RouteMetric=9;Protocol=65535}
            } else { [pscustomobject]@{DestinationPrefix='10.21.20.64/28';NextHop='0.0.0.0';RouteMetric=256;Protocol='Local'} }
        }
        $routes=@(Get-TargetStaticRoutes -InterfaceIndex 8)
        Assert-True ($routes.Count -eq 1 -and $routes[0].store -eq 'PersistentStore' -and $routes[0].destinationPrefix -eq '198.51.100.0/24') 'Rollback snapshot missed a persistent-only static route.'
    }
    Test-Case 'Uncaptured route interfaces are retained with an explicit warning' {
        Initialize-MultiNicFixture
        $script:SchemaVersion='1.0';$script:IpConfigPath='ipconfig.txt';$script:RoutePath='routes.txt';$script:ArpPath='arp.txt'
        function Get-ActiveAdapters { $script:PreNetwork.activeAdapters }
        function Get-StructuredRoutes { [pscustomobject]@{interfaceIndex=14;destinationPrefix='0.0.0.0/0';nextHop='192.0.2.1';isPersistentOrStatic=$true} }
        $network=Get-NetworkCapture
        Assert-MigrationNetworkCaptureComplete $network
        Assert-True ($network.ipv4Routes.Count -eq 1 -and $network.ipv4Routes[0].interfaceIndex -eq 14) 'Uncaptured route was discarded.'
        Assert-True (@($script:Results | Where-Object { $_.name -eq 'Routes on uncaptured interfaces' -and $_.state -eq 'WARNING' }).Count -eq 1) 'The omitted automatic restoration was not reported.'
    }
    Test-Case 'Eight NICs and 800 static IPv4 routes retain ownership metrics and persistence at scale' {
        $sources=@();$script:ScaleTargets=@();$script:ScaleActive=@();$script:ScalePersistent=@()
        for ($nic=1; $nic -le 8; $nic++) {
            $mac='02-00-00-00-01-{0:X2}' -f $nic
            $sources += [pscustomobject]@{interfaceAlias="Source$nic";interfaceIndex=(20+$nic);macAddress=$mac}
            $script:ScaleTargets += [pscustomobject]@{isVirtIO=$true;adapter=[pscustomobject]@{interfaceAlias="Target$nic";interfaceIndex=(200+$nic);macAddress=$mac}}
            for ($routeNumber=1; $routeNumber -le 100; $routeNumber++) {
                # Reuse destinations on all NICs to prove that route ownership is not guessed from its prefix.
                $nextHop=if ($routeNumber % 3 -eq 0) { '0.0.0.0' } elseif ($routeNumber % 3 -eq 1) { "10.$nic.0.1" } else { "10.$nic.0.2" }
                $record=[pscustomobject]@{ifIndex=(20+$nic);DestinationPrefix="192.0.$routeNumber.0/24";NextHop=$nextHop;RouteMetric=($nic+$routeNumber);Protocol='NetMgmt'}
                $script:ScaleActive += $record
                if ($routeNumber % 2 -eq 0) {
                    $script:ScalePersistent += [pscustomobject]@{ifIndex=$record.ifIndex;DestinationPrefix=$record.DestinationPrefix;NextHop=$nextHop;RouteMetric=$record.RouteMetric;Protocol=65535}
                }
            }
            $script:ScaleActive += [pscustomobject]@{ifIndex=(20+$nic);DestinationPrefix="10.$nic.0.0/24";NextHop='0.0.0.0';RouteMetric=256;Protocol='Local'}
            $script:ScaleActive += [pscustomobject]@{ifIndex=(20+$nic);DestinationPrefix="198.51.$nic.0/24";NextHop="10.$nic.0.1";RouteMetric=10;Protocol='Dhcp'}
        }
        $script:ScalePersistent += [pscustomobject]@{ifIndex=999;DestinationPrefix='203.0.113.0/24';NextHop='192.0.2.1';RouteMetric=9;Protocol=$null}
        [array]::Reverse($script:ScaleTargets)
        function Get-NetRoute { param($AddressFamily,$PolicyStore) if ($PolicyStore -eq 'PersistentStore') { $script:ScalePersistent } else { $script:ScaleActive } }
        function Get-NetAdapter { param($InterfaceIndex) if ($InterfaceIndex -ne 999) { [pscustomobject]@{Name="NIC$InterfaceIndex"} } }
        function Find-VirtIOAdapters { $script:ScaleTargets }
        $routes=@(Get-StructuredRoutes)
        Assert-True ($routes.Count -eq 817 -and @($routes | Where-Object store -eq 'PersistentStore').Count -eq 401) 'Export dropped or duplicated records across NICs/stores.'
        $script:PreNetwork=[pscustomobject]@{activeAdapters=$sources;ipv4Routes=$routes}
        $plan=@(Resolve-AdapterMapping)
        Assert-True ($plan.Count -eq 8) 'Mapping imposed a two-NIC limit.'
        $script:ScaleApplied=@{}
        function Set-MigrationRoute {
            param($Route,$InterfaceIndex)
            Assert-True ($InterfaceIndex -eq $Route.interfaceIndex+180) 'A route crossed into the wrong target NIC.'
            Assert-True ($Route.routeMetric -eq ($Route.interfaceIndex-20)+[int]($Route.destinationPrefix.Split('.')[2])) 'Route metric changed.'
            $number=[int]($Route.destinationPrefix.Split('.')[2])
            $expectedStore=if ($number % 2 -eq 0) { 'PersistentStore' } else { 'ActiveStore' }
            Assert-True ($Route.store -eq $expectedStore) 'Persistence changed.'
            $key="$InterfaceIndex|$($Route.destinationPrefix)|$($Route.nextHop)"
            Assert-True (-not $script:ScaleApplied.ContainsKey($key)) 'A route was applied twice.'
            $script:ScaleApplied[$key]=$Route
        }
        foreach ($entry in $plan) { Restore-StaticRoutes $entry -Confirm:$false }
        Assert-True ($script:ScaleApplied.Count -eq 800) 'Some static routes were omitted or connected/dynamic/orphan routes were applied.'
        # Repeat identity resolution with eight changed MACs and an explicit mapping file.
        $entries=@(foreach ($target in $script:ScaleTargets) {
            $oldMac=$target.adapter.macAddress
            $target.adapter.macAddress='02-00-00-00-02-{0:X2}' -f ($target.adapter.interfaceIndex-200)
            [pscustomobject]@{sourceMacAddress=$oldMac;targetMacAddress=$target.adapter.macAddress}
        })
        $script:AdapterMappingPath=Join-Path $script:TempRoot 'eight-nic-map.json'
        [pscustomobject]@{schemaVersion='1.0';mappings=$entries} | ConvertTo-Json -Depth 4 | Set-Content $script:AdapterMappingPath
        $explicitPlan=@(Resolve-AdapterMapping)
        Assert-True ($explicitPlan.Count -eq 8) 'Explicit mapping did not scale to eight changed NICs.'
        foreach ($entry in $explicitPlan) { Assert-True ($entry.target.adapter.interfaceIndex -eq $entry.source.interfaceIndex+180) 'Explicit mapping swapped NICs.' }
    }
    Test-Case 'A leftover Balloon log does not block confirmed Firstboot completion' {
        function Get-CimInstance { param($ClassName) @() }
        $path=Join-Path $script:TempRoot 'firstboot-balloon-log'
        New-Item -ItemType Directory -Path (Join-Path $path 'scripts') -Force | Out-Null
        'installer output' | Set-Content (Join-Path $path 'scripts/balloon.log')
        'Service uninstalled successfully' | Set-Content (Join-Path $path 'log.txt')
        $state=Get-MigrationFirstbootState -Path $path
        Assert-True ($state.state -eq 'Complete' -and $state.pendingScripts.Count -eq 0 -and $state.ignoredLogFiles[0] -eq 'balloon.log') 'The installer log was mistaken for a pending script.'
        Remove-Item (Join-Path $path 'log.txt')
        New-Item -ItemType File -Path (Join-Path $path 'complete') | Out-Null
        Assert-True ((Get-MigrationFirstbootState -Path $path).state -eq 'Complete') 'The sentinel was not accepted with a leftover installer log.'
    }
    Test-Case 'A leftover log alone cannot establish Firstboot completion' {
        function Get-CimInstance { param($ClassName) @() }
        $path=Join-Path $script:TempRoot 'firstboot-log-without-completion'
        New-Item -ItemType Directory -Path (Join-Path $path 'scripts') -Force | Out-Null
        'installer output' | Set-Content (Join-Path $path 'scripts/balloon.log')
        $state=Get-MigrationFirstbootState -Path $path
        Assert-True ($state.state -eq 'Unknown' -and $state.pendingScripts.Count -eq 0) 'Ignoring a log bypassed completion verification.'
    }
    Test-Case 'An active Firstboot service remains blocking with logs and a completion marker' {
        function Get-CimInstance { param($ClassName) [pscustomobject]@{Name='firstboot';PathName='firstboot.exe'} }
        $path=Join-Path $script:TempRoot 'firstboot-active-with-log'
        New-Item -ItemType Directory -Path (Join-Path $path 'scripts') -Force | Out-Null
        'installer output' | Set-Content (Join-Path $path 'scripts/BALLOON.LOG')
        New-Item -ItemType File -Path (Join-Path $path 'complete') | Out-Null
        $state=Get-MigrationFirstbootState -Path $path
        Assert-True ($state.state -eq 'Pending' -and $state.serviceCount -eq 1 -and $state.pendingScripts.Count -eq 0) 'An active conversion was released by the log-file exception.'
    }
    Test-Case 'Actual scripts and unknown non-log files remain blocking alongside installer logs' {
        function Get-CimInstance { param($ClassName) @() }
        $path=Join-Path $script:TempRoot 'firstboot-pending-with-log'
        New-Item -ItemType Directory -Path (Join-Path $path 'scripts') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $path 'complete') | Out-Null
        'installer output' | Set-Content (Join-Path $path 'scripts/balloon.log')
        foreach ($file in @('5000-install.bat','install.cmd','install.ps1','unknown.payload')) {
            $pendingPath=Join-Path $path "scripts/$file"
            'pending work' | Set-Content $pendingPath
            $state=Get-MigrationFirstbootState -Path $path
            Assert-True ($state.state -eq 'Pending' -and $state.pendingScripts.Count -eq 1 -and $state.pendingScripts[0] -eq $file) 'Actual or unknown work was ignored.'
            Remove-Item $pendingPath
        }
    }
    Test-Case 'Installed Balloon and QEMU payloads below Firstboot do not become conversion runners' {
        function Get-CimInstance {
            param($ClassName)
            [pscustomobject]@{Name='Balloon1073';State='Running';StartMode='Auto';PathName='"C:\Program Files\Guestfs\Firstboot\Temp\blnsvr.exe" -s'}
            [pscustomobject]@{Name='QEMU-GA';State='Running';StartMode='Auto';PathName='C:\Program Files\Guestfs\Firstboot\qemu-ga.exe -d'}
        }
        $path=Join-Path $script:TempRoot 'firstboot-installed-payloads'
        New-Item -ItemType Directory -Path (Join-Path $path 'scripts') -Force | Out-Null
        'installer output' | Set-Content (Join-Path $path 'scripts/balloon.log')
        'Service uninstalled successfully' | Set-Content (Join-Path $path 'log.txt')
        $state=Get-MigrationFirstbootState -Path $path
        Assert-True ($state.state -eq 'Complete' -and $state.serviceCount -eq 0 -and $state.installedPayloadServices.Count -eq 2) 'An installed payload was mistaken for an active conversion.'
        Remove-Item (Join-Path $path 'log.txt')
        Assert-True ((Get-MigrationFirstbootState -Path $path).state -eq 'Unknown') 'Payload recognition bypassed completion evidence.'
    }
    Test-Case 'A real Firstboot service still blocks completion alongside installed Balloon' {
        function Get-CimInstance {
            param($ClassName)
            [pscustomobject]@{Name='Balloon1073';State='Running';StartMode='Auto';PathName='"C:\Program Files\Guestfs\Firstboot\Temp\blnsvr.exe"'}
            [pscustomobject]@{Name='firstboot';State='Stopped';StartMode='Auto';PathName='"C:\Program Files\Guestfs\Firstboot\rhsrvany.exe"'}
        }
        $path=Join-Path $script:TempRoot 'firstboot-runner-with-balloon'
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $path 'complete') | Out-Null
        $state=Get-MigrationFirstbootState -Path $path
        Assert-True ($state.state -eq 'Pending' -and $state.serviceCount -eq 1 -and $state.services[0].name -eq 'firstboot' -and $state.services[0].state -eq 'Stopped') 'A stopped Firstboot runner was ignored.'
    }
    Test-Case 'Unknown Firstboot services cannot bypass the gate using payload names in arguments' {
        function Get-CimInstance {
            param($ClassName)
            [pscustomobject]@{Name='ConversionRunner';State='Running';StartMode='Auto';PathName='"C:\Program Files\Guestfs\Firstboot\custom-runner.exe" "C:\Program Files\Guestfs\Firstboot\blnsvr.exe"'}
        }
        $path=Join-Path $script:TempRoot 'firstboot-unknown-runner'
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $path 'complete') | Out-Null
        $state=Get-MigrationFirstbootState -Path $path
        Assert-True ($state.state -eq 'Pending' -and $state.serviceCount -eq 1 -and $state.installedPayloadServices.Count -eq 0) 'An unknown runner was mistaken for its payload argument.'
    }
    Test-Case 'Firstboot service identity takes priority over a recognized payload executable' {
        function Get-CimInstance { param($ClassName) [pscustomobject]@{Name='firstboot';State='Running';StartMode='Auto';PathName='"C:\Program Files\Guestfs\Firstboot\blnsvr.exe"'} }
        $path=Join-Path $script:TempRoot 'firstboot-name-priority'
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $path 'complete') | Out-Null
        Assert-True ((Get-MigrationFirstbootState -Path $path).state -eq 'Pending') 'Known Firstboot identity was bypassed by its executable name.'
    }
    Test-Case 'Firstboot failures show blocking service details even with no pending scripts' {
        function Get-MigrationFirstbootState { [pscustomobject]@{state='Pending';services=@([pscustomobject]@{name='firstboot';state='Stopped';startMode='Auto';pathName='C:\Firstboot\rhsrvany.exe'});pendingScripts=@();completeMarkerPresent=$false;lastLogLine='still working';path='C:\Firstboot'} }
        $message=''
        try { Assert-MigrationFirstbootComplete } catch { $message=$_.Exception.Message }
        Assert-True ($message -match 'firstboot: state=Stopped, start=Auto' -and $message -match 'Pending scripts: none' -and $message -match 'Last Firstboot log line: still working') 'The error does not identify its blocking evidence.'
    }
    Test-Case 'Firstboot restart hint requires the complete cleanup evidence and never bypasses the gate' {
        $script:HintStatus=[pscustomobject]@{state='Pending';services=@([pscustomobject]@{name='firstboot';state='Running';startMode='Disabled';pathName='C:\Firstboot\rhsrvany.exe'});pendingScripts=@();lastLogLine='Service uninstalled successfully'}
        function Get-MigrationFirstbootState { $script:HintStatus }
        Assert-Throws { Assert-MigrationFirstbootComplete } 'MIG-FIRSTBOOT-002.*'
        $message=''; try { Assert-MigrationFirstbootComplete } catch { $message=$_.Exception.Message }
        Assert-True ($message -match 'restart Windows once' -and $message -match '3\) ValidatePost again') 'Restart instruction is missing.'
        foreach ($variant in @('pending script','running conversion','enabled service','unknown runner')) {
            $script:HintStatus.pendingScripts=@()
            $script:HintStatus.lastLogLine='Service uninstalled successfully'
            $script:HintStatus.services[0].startMode='Disabled'
            $script:HintStatus.services[0].name='firstboot'
            switch ($variant) {
                'pending script' { $script:HintStatus.pendingScripts=@('install.bat') }
                'running conversion' { $script:HintStatus.lastLogLine='Installing drivers' }
                'enabled service' { $script:HintStatus.services[0].startMode='Auto' }
                'unknown runner' { $script:HintStatus.services[0].name='UnknownRunner' }
            }
            $message=''; try { Assert-MigrationFirstbootComplete } catch { $message=$_.Exception.Message }
            Assert-True ($message -match 'MIG-FIRSTBOOT-001' -and $message -notmatch 'restart Windows once') "Unsafe restart hint for $variant."
        }
    }
    Test-Case 'The observed multi-NIC planning warnings do not masquerade as a network capture failure' {
        $script:Mode='Full'
        $script:PreState=[pscustomobject]@{captureStatus=[pscustomobject]@{complete=$false;warnings=@(
            'Active network adapters: 2 active adapters detected. All adapters will be exported; however, preserve each source MAC on the target or supply an explicit adapter mapping for post-restore network configuration.',
            'Routes on uncaptured interfaces: Saved routes on interfaces outside the captured active NICs are retained for reference and will not be assigned to another NIC automatically.',
            'Collection unavailable: bitLocker'
        )}}
        Assert-True (Test-CaptureCompleteness) 'Planning warnings incorrectly blocked a complete network capture.'
        Assert-True ($script:Results[0].state -eq 'WARNING' -and $script:Results[0].details.Count -eq 3) 'Capture warnings were lost or reported as PASS.'
    }
    Test-Case 'Actual network and raw-output capture failures still block mutating restore modes' {
        foreach ($restoreMode in @('Full','ApplyNetwork')) {
            $script:Mode=$restoreMode
            foreach ($warning in @('Network configuration: Capture was not available; the remaining capture continued.','Raw network outputs: One or more raw network outputs could not be captured completely.')) {
                $script:PreState=[pscustomobject]@{captureStatus=[pscustomobject]@{complete=$false;warnings=@($warning)}}
                Assert-True (-not (Test-CaptureCompleteness)) 'An actual capture failure did not block restoration.'
            }
        }
        Assert-True (@($script:Results | Where-Object state -eq 'FAIL').Count -eq 4) 'A capture failure was hidden.'
    }
    Test-Case 'Read-only validation retains capture warnings without approving network changes' {
        $script:Mode='ValidateOnly'
        $script:PreState=[pscustomobject]@{captureStatus=[pscustomobject]@{complete=$false;warnings=@('Network configuration: Capture was not available; the remaining capture continued.')}}
        Assert-True (Test-CaptureCompleteness) 'Read-only comparison was blocked unnecessarily.'
        Assert-True ($script:Results[0].state -eq 'WARNING') 'Read-only validation hid an incomplete baseline.'
    }
    Test-Case 'Repeated preparation ROOT devices warn separately from a healthy PCI storage controller' {
        $devices=@(1..17 | ForEach-Object { [pscustomobject]@{InstanceId=('ROOT\VIOSCSI\{0:X4}' -f $_);FriendlyName='Red Hat VirtIO SCSI pass-through controller';Status='Error';ProblemCode=28} })
        $devices += [pscustomobject]@{InstanceId='PCI\VEN_1AF4&DEV_1004\REAL';FriendlyName='Red Hat VirtIO SCSI pass-through controller';Status='OK';ProblemCode=0}
        Invoke-StorageHealthFixture -Devices $devices
        Assert-True (@($script:Results | Where-Object state -eq 'FAIL').Count -eq 0) 'Known preparation devices failed the hardware check.'
        $warning=@($script:Results | Where-Object name -eq 'Preparation ROOT storage devices')[0]
        Assert-True ($warning.state -eq 'WARNING' -and $warning.details.Count -eq 17 -and $warning.details[0] -match 'ROOT\\VIOSCSI' -and $warning.details[0] -match 'ProblemCode=28') 'Root device evidence was hidden.'
        Assert-True (@($script:Results | Where-Object { $_.name -eq 'Storage driver health' -and $_.state -eq 'PASS' }).Count -eq 1) 'Healthy hardware controller was not checked.'
    }
    Test-Case 'A real failing PCI controller cannot be hidden by preparation ROOT devices or friendly names' {
        Invoke-StorageHealthFixture -Devices @(
            [pscustomobject]@{InstanceId='ROOT\VIOSCSI\0000';FriendlyName='Red Hat VirtIO SCSI pass-through controller';Status='Error';ProblemCode=28},
            [pscustomobject]@{InstanceId='PCI\VEN_1AF4&DEV_1004\REAL';FriendlyName='Red Hat VirtIO SCSI pass-through controller';Status='Error';ProblemCode=10}
        )
        $failure=@($script:Results | Where-Object { $_.name -eq 'Storage driver health' -and $_.state -eq 'FAIL' })
        Assert-True ($failure.Count -eq 1 -and $failure[0].details[0] -match 'InstanceId=PCI' -and $failure[0].details[0] -match 'ProblemCode=10') 'A hardware failure was exempted or lacks diagnostic identity.'
    }
    Test-Case 'An unknown ROOT storage controller with a VirtIO name remains a failure' {
        Invoke-StorageHealthFixture -Devices @([pscustomobject]@{InstanceId='ROOT\OTHERSTORAGE\0000';FriendlyName='Red Hat VirtIO SCSI pass-through controller';Status='Error';ProblemCode=28})
        Assert-True (@($script:Results | Where-Object state -eq 'FAIL').Count -eq 1) 'Friendly-name matching hid an unrelated ROOT device failure.'
    }
    Test-Case 'ROOT identity needs the preparation hardware ID and readable metadata' {
        Invoke-StorageHealthFixture -Devices @([pscustomobject]@{InstanceId='ROOT\VIOSCSI\0000';FriendlyName='VirtIO SCSI Controller';Status='Error';ProblemCode=28;HardwareIds=@('PCI\VEN_1234&DEV_1004')})
        Assert-True (@($script:Results | Where-Object state -eq 'FAIL').Count -eq 1) 'Wrong hardware identity was exempted.'
        $script:Results.Clear()
        Invoke-StorageHealthFixture -MetadataFailure -Devices @([pscustomobject]@{InstanceId='ROOT\VIOSCSI\0000';FriendlyName='VirtIO SCSI Controller';Status='Error';ProblemCode=28})
        Assert-True (@($script:Results | Where-Object state -eq 'FAIL').Count -eq 1 -and @($script:Results | Where-Object name -eq 'Storage device metadata').Count -eq 1) 'Missing identity metadata silently exempted a device.'
    }
    Test-Case 'Only preparation devices cannot establish hardware storage health' {
        Invoke-StorageHealthFixture -Devices @([pscustomobject]@{InstanceId='ROOT\VIOSCSI\0000';FriendlyName='VirtIO SCSI Controller';Status='Error';ProblemCode=28})
        Assert-True (@($script:Results | Where-Object { $_.name -eq 'Storage driver health' -and $_.state -eq 'NOT_CHECKED' }).Count -eq 1) 'A preparation device was treated as proof of hardware health.'
        Assert-True (@($script:Results | Where-Object state -eq 'PASS').Count -eq 0) 'Missing hardware was approved.'
    }
    Test-Case 'Block preparation device identity is recognized without exempting another hardware family' {
        Invoke-StorageHealthFixture -Devices @(
            [pscustomobject]@{InstanceId='ROOT\VIOSTOR\0000';FriendlyName='VirtIO Block Controller';Status='Error';ProblemCode=28;HardwareIds=@('PCI\VEN_1AF4&DEV_1001')},
            [pscustomobject]@{InstanceId='PCI\VEN_1AF4&DEV_1004\REAL';FriendlyName='VirtIO SCSI Controller';Status='OK';ProblemCode=0}
        )
        Assert-True (@($script:Results | Where-Object name -eq 'Preparation ROOT storage devices').Count -eq 1 -and @($script:Results | Where-Object state -eq 'FAIL').Count -eq 0) 'SCSI/Block classification was conflated.'
    }
    Test-Case 'Nonzero PCI problem codes and unavailable PnP enumeration cannot yield a clean pass' {
        Invoke-StorageHealthFixture -Devices @([pscustomobject]@{InstanceId='PCI\VEN_1AF4&DEV_1004\REAL';FriendlyName='VirtIO SCSI Controller';Status='OK';ProblemCode=10})
        Assert-True (@($script:Results | Where-Object state -eq 'FAIL').Count -eq 1) 'A nonzero device problem code was hidden.'
        $script:Results.Clear()
        Invoke-StorageHealthFixture -EnumerationFailure -Devices @()
        Assert-True (@($script:Results | Where-Object state -eq 'NOT_CHECKED').Count -eq 1 -and @($script:Results | Where-Object state -eq 'PASS').Count -eq 0) 'Unavailable enumeration was approved.'
    }
    Write-Host "Tests passed: $script:Passed; failed: $script:Failures"
} finally {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:Failures -gt 0) { exit 1 }
exit 0
