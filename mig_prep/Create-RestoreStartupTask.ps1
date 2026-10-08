<#
.SYNOPSIS
    Creates a Windows Scheduled Task to restore network settings at startup after Proxmox migration.

.DESCRIPTION
    Creates an automated Windows Scheduled Task that runs at system startup (before user logon)
    with SYSTEM account privileges. The task executes Restore-And-TestMigrationState.ps1 in
    ApplyNetwork mode to restore static network configuration captured before migration.
    
    This solves the chicken-and-egg problem: Domain login requires network, but network
    configuration isn't applied until the restore script runs. By executing at startup with
    SYSTEM privileges, network is functional before the domain login prompt appears.
    
    The task automatically disables itself after successful completion to prevent repeated execution.

.PARAMETER RestoreScriptPath
    Full path to Restore-And-TestMigrationState.ps1 script.
    Required.

.PARAMETER StateDirectory
    Full path to the directory containing PreMigrationState.json and NetworkConfiguration.json.
    This is typically the 'State' subdirectory from Export-MigrationState output.
    Required.

.PARAMETER TaskName
    Name for the scheduled task. Default: 'Restore Network on Boot'.

.PARAMETER TaskDescription
    Description for the scheduled task. Default: 'Restores network settings after Proxmox migration'.

.EXAMPLE
    .\Create-RestoreStartupTask.ps1 `
        -RestoreScriptPath 'C:\Rutin_migration_2026-10-08\Restore-And-TestMigrationState\Restore-And-TestMigrationState.ps1' `
        -StateDirectory 'C:\Rutin_migration_2026-10-08\Export-MigrationState\State'

.EXAMPLE
    .\Create-RestoreStartupTask.ps1 `
        -RestoreScriptPath 'C:\path\to\Restore-And-TestMigrationState.ps1' `
        -StateDirectory 'C:\path\to\state' `
        -TaskName 'My Custom Task Name'

.NOTES
    Supported targets: Windows Server 2016, 2019, 2022, and 2025; PowerShell 5.1+.
    Requires administrator privileges.
    Task runs with SYSTEM account (no user credentials required).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$RestoreScriptPath,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$StateDirectory,

    [string]$TaskName = 'Restore Network on Boot',
    [string]$TaskDescription = 'Restores network settings after Proxmox migration'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-ScheduledTaskTrigger-AtStartup {
    <#
    .SYNOPSIS
        Creates a scheduled task trigger for system startup.
    .NOTES
        Wrapper for compatibility across PowerShell versions.
    #>
    $trigger = New-ScheduledTaskTrigger -AtStartup
    return $trigger
}

function New-ScheduledTaskPrincipal-System {
    <#
    .SYNOPSIS
        Creates a scheduled task principal for SYSTEM account with highest privileges.
    #>
    $principal = New-ScheduledTaskPrincipal `
        -UserId 'NT AUTHORITY\SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest
    return $principal
}

function New-ScheduledTaskAction-RestoreNetwork {
    <#
    .SYNOPSIS
        Creates the scheduled task action to run the restore script in ApplyNetwork mode.
    #>
    param([string]$ScriptPath, [string]$StateDir)
    
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$ScriptPath`"",
        '-Mode', 'ApplyNetwork',
        '-StateDirectory', "`"$StateDir`""
    ) -join ' '
    
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument $arguments `
        -WorkingDirectory (Split-Path $ScriptPath -Parent)
    
    return $action
}

try {
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Creating scheduled task '$TaskName'..." -ForegroundColor Cyan
    
    # Verify administrator privileges
    if (-not (Test-Administrator)) {
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: Administrator privileges are required." -ForegroundColor Red
        exit 1
    }
    
    # Normalize paths
    $RestoreScriptPath = (Resolve-Path $RestoreScriptPath).Path
    $StateDirectory = (Resolve-Path $StateDirectory).Path
    
    # Check if task already exists
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Task '$TaskName' already exists. Removing..." -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null
        Start-Sleep -Milliseconds 500
    }
    
    # Create task components
    $trigger = New-ScheduledTaskTrigger-AtStartup
    $principal = New-ScheduledTaskPrincipal-System
    $action = New-ScheduledTaskAction-RestoreNetwork -ScriptPath $RestoreScriptPath -StateDir $StateDirectory
    
    # Create task settings
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable:$false
    
    # Register the task
    $task = Register-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath '\' `
        -Trigger $trigger `
        -Action $action `
        -Principal $principal `
        -Settings $settings `
        -Description $TaskDescription `
        -Force
    
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Task created successfully." -ForegroundColor Green
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Task Name: $($task.TaskName)" -ForegroundColor Gray
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Task Path: $($task.TaskPath)" -ForegroundColor Gray
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Principal: $($principal.UserId) (RunLevel: $($principal.RunLevel))" -ForegroundColor Gray
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Trigger: At Startup" -ForegroundColor Gray
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Script: $RestoreScriptPath" -ForegroundColor Gray
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] State Directory: $StateDirectory" -ForegroundColor Gray
    
    Write-Host "`nTask will execute at next system startup and automatically disable after successful network restoration." -ForegroundColor Cyan
    exit 0
}
catch {
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) {
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Inner error: $($_.Exception.InnerException.Message)" -ForegroundColor Red
    }
    exit 99
}
