<#
.SYNOPSIS
    Orchestrates VMware-to-Proxmox migration workflow with guided phase selection.

.DESCRIPTION
    Provides an interactive workflow that guides users through pre-migration preparation,
    migration execution, and post-migration validation. Automatically calls dependent scripts
    based on server role (Domain Controller vs. Normal Server) selection.

.PARAMETER Phase
    Optional: Specify phase directly (ReadinessCheck, Prepare, ValidatePost).
    If not provided, displays interactive menu.

.EXAMPLE
    .\Migrate-VmwareToProxmox.ps1
    # Interactive menu displayed

.EXAMPLE
    .\Migrate-VmwareToProxmox.ps1 -Phase ReadinessCheck

.EXAMPLE
    .\Migrate-VmwareToProxmox.ps1 -Phase Prepare

.EXAMPLE
    .\Migrate-VmwareToProxmox.ps1 -Phase ValidatePost

.NOTES
    Supported targets: Windows Server 2016, 2019, 2022, and 2025; PowerShell 5.1+.
    Calls dependent scripts: mig_prep, Export-MigrationState, Test-MigrationReadiness,
    Test-DCMigrationHealth, Restore-And-TestMigrationState.
#>
[CmdletBinding()]
param(
    [ValidateSet('ReadinessCheck', 'Prepare', 'ValidatePost')]
    [string]$Phase
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

function Get-StateColor {
    param([string]$State)
    switch ($State) {
        'INFO' { return [ConsoleColor]::Cyan }
        'SUCCESS' { return [ConsoleColor]::Green }
        'WARNING' { return [ConsoleColor]::Yellow }
        'ERROR' { return [ConsoleColor]::Red }
        default { return [ConsoleColor]::Gray }
    }
}

function Write-Status {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$State = 'INFO'
    )
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $prefix = switch ($State) {
        'INFO' { '[INFO]' }
        'SUCCESS' { '[✓]' }
        'WARNING' { '[⚠]' }
        'ERROR' { '[✗]' }
    }
    Write-Host "[$timestamp] $prefix $Message" -ForegroundColor (Get-StateColor $State)
}

function Show-MainMenu {
    Write-Host "`n" -NoNewline
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  VMware-to-Proxmox Migration Orchestration" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "`n  Select a migration phase:`n"
    Write-Host "  1) ReadinessCheck   - Pre-migration validation and preparation checks" -ForegroundColor Green
    Write-Host "  2) Prepare          - Install VirtIO drivers and capture system state" -ForegroundColor Green
    Write-Host "  3) ValidatePost     - Validate and restore network after migration" -ForegroundColor Green
    Write-Host "  4) Exit" -ForegroundColor Gray
    Write-Host "`n"
}

function Show-ServerTypeMenu {
    Write-Host "`n  Is this server a Domain Controller or Normal Server?`n"
    Write-Host "  1) Domain Controller   - Runs DC-specific health checks" -ForegroundColor Green
    Write-Host "  2) Normal Server       - Runs standard validation only" -ForegroundColor Green
    Write-Host "  3) Cancel              - Return to main menu" -ForegroundColor Gray
    Write-Host "`n"
}

function Get-PhaseSelection {
    do {
        Show-MainMenu
        $choice = Read-Host "Enter selection"
        
        switch ($choice) {
            '1' { return 'ReadinessCheck' }
            '2' { return 'Prepare' }
            '3' { return 'ValidatePost' }
            '4' { Write-Status "Exiting." 'INFO'; exit 0 }
            default { Write-Status "Invalid selection. Please enter 1, 2, 3, or 4." 'WARNING' }
        }
    } while ($true)
}

function Get-ServerTypeSelection {
    do {
        Show-ServerTypeMenu
        $choice = Read-Host "Enter selection"
        
        switch ($choice) {
            '1' { return 'DomainController' }
            '2' { return 'Normal' }
            '3' { return $null }
            default { Write-Status "Invalid selection. Please enter 1, 2, or 3." 'WARNING' }
        }
    } while ($true)
}

function Invoke-ReadinessCheck {
    Write-Status "Starting ReadinessCheck phase..." 'INFO'
    
    $serverType = Get-ServerTypeSelection
    if ($null -eq $serverType) {
        Write-Status "ReadinessCheck cancelled." 'WARNING'
        return
    }
    
    Write-Status "Server type: $serverType" 'INFO'
    Write-Status "Running Test-MigrationReadiness..." 'INFO'
    
    $testReadinessPath = Join-Path $PSScriptRoot 'Test-MigrationReadiness.ps1'
    if (-not (Test-Path $testReadinessPath)) {
        Write-Status "Error: Test-MigrationReadiness.ps1 not found at $testReadinessPath" 'ERROR'
        return
    }
    
    & $testReadinessPath
    if ($LASTEXITCODE -ne 0) {
        Write-Status "Test-MigrationReadiness completed with warnings or errors." 'WARNING'
    } else {
        Write-Status "Test-MigrationReadiness completed successfully." 'SUCCESS'
    }
    
    if ($serverType -eq 'DomainController') {
        Write-Status "Running Test-DCMigrationHealth (pre-migration mode)..." 'INFO'
        
        $testDCHealthPath = Join-Path $PSScriptRoot 'Test-DCMigrationHealth.ps1'
        if (-not (Test-Path $testDCHealthPath)) {
            Write-Status "Error: Test-DCMigrationHealth.ps1 not found at $testDCHealthPath" 'ERROR'
            return
        }
        
        & $testDCHealthPath -Mode PreMigration
        if ($LASTEXITCODE -ne 0) {
            Write-Status "Test-DCMigrationHealth completed with warnings or errors." 'WARNING'
        } else {
            Write-Status "Test-DCMigrationHealth completed successfully." 'SUCCESS'
        }
    }
    
    Write-Status "ReadinessCheck phase completed." 'SUCCESS'
}

function Invoke-Prepare {
    Write-Status "Starting Prepare phase..." 'INFO'
    
    Write-Status "Running mig_prep (VirtIO driver installation)..." 'INFO'
    
    $migPrepPath = Join-Path $PSScriptRoot 'mig_prep.ps1'
    if (-not (Test-Path $migPrepPath)) {
        Write-Status "Error: mig_prep.ps1 not found at $migPrepPath" 'ERROR'
        return
    }
    
    & $migPrepPath -AllowUnsignedInstaller
    if ($LASTEXITCODE -ne 0) {
        Write-Status "mig_prep completed with warnings or errors." 'WARNING'
    } else {
        Write-Status "mig_prep completed successfully." 'SUCCESS'
    }
    
    Write-Status "Running Export-MigrationState (system state capture)..." 'INFO'
    
    $exportStatePath = Join-Path $PSScriptRoot 'Export-MigrationState.ps1'
    if (-not (Test-Path $exportStatePath)) {
        Write-Status "Error: Export-MigrationState.ps1 not found at $exportStatePath" 'ERROR'
        return
    }
    
    & $exportStatePath
    if ($LASTEXITCODE -ne 0) {
        Write-Status "Export-MigrationState completed with warnings or errors." 'WARNING'
    } else {
        Write-Status "Export-MigrationState completed successfully." 'SUCCESS'
    }
    
    Write-Status "Prepare phase completed." 'SUCCESS'
}

function Invoke-ValidatePost {
    Write-Status "Starting ValidatePost phase..." 'INFO'
    
    $serverType = Get-ServerTypeSelection
    if ($null -eq $serverType) {
        Write-Status "ValidatePost cancelled." 'WARNING'
        return
    }
    
    Write-Status "Server type: $serverType" 'INFO'
    Write-Status "Running Restore-And-TestMigrationState..." 'INFO'
    
    $restoreStatePath = Join-Path $PSScriptRoot 'Restore-And-TestMigrationState.ps1'
    if (-not (Test-Path $restoreStatePath)) {
        Write-Status "Error: Restore-And-TestMigrationState.ps1 not found at $restoreStatePath" 'ERROR'
        return
    }
    
    & $restoreStatePath -Mode Full
    if ($LASTEXITCODE -ne 0) {
        Write-Status "Restore-And-TestMigrationState completed with warnings or errors." 'WARNING'
    } else {
        Write-Status "Restore-And-TestMigrationState completed successfully." 'SUCCESS'
    }
    
    if ($serverType -eq 'DomainController') {
        Write-Status "Running Test-DCMigrationHealth (post-migration mode)..." 'INFO'
        
        $testDCHealthPath = Join-Path $PSScriptRoot 'Test-DCMigrationHealth.ps1'
        if (-not (Test-Path $testDCHealthPath)) {
            Write-Status "Error: Test-DCMigrationHealth.ps1 not found at $testDCHealthPath" 'ERROR'
            return
        }
        
        & $testDCHealthPath -Mode PostMigration
        if ($LASTEXITCODE -ne 0) {
            Write-Status "Test-DCMigrationHealth completed with warnings or errors." 'WARNING'
        } else {
            Write-Status "Test-DCMigrationHealth completed successfully." 'SUCCESS'
        }
    }
    
    Write-Status "ValidatePost phase completed." 'SUCCESS'
}

try {
    Write-Status "Migration Orchestration Script Started" 'INFO'
    
    # Get phase selection
    if ([string]::IsNullOrWhiteSpace($Phase)) {
        $Phase = Get-PhaseSelection
    }
    
    # Execute phase
    switch ($Phase) {
        'ReadinessCheck' { Invoke-ReadinessCheck }
        'Prepare' { Invoke-Prepare }
        'ValidatePost' { Invoke-ValidatePost }
        default { Write-Status "Unknown phase: $Phase" 'ERROR'; exit 1 }
    }
    
    Write-Status "All operations completed." 'SUCCESS'
    exit 0
} catch {
    Write-Status "Unexpected error: $($_.Exception.Message)" 'ERROR'
    exit 99
}
