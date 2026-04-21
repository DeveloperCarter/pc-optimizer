[CmdletBinding()]
param(
    [switch]$Analyze,
    [switch]$Optimize,
    [switch]$Rollback,

    [ValidateSet('Balanced', 'BestPerformance', 'BatterySaver')]
    [string]$Profile = 'Balanced',

    [switch]$WhatIfOnly,
    [switch]$SkipAcerChecks,

    [string]$BackupRoot = '.\optimizer-backups',
    [string]$RollbackManifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
}

function Write-Item {
    param(
        [string]$Key,
        [string]$Value,
        [ValidateSet('Info', 'Warn', 'Ok')]
        [string]$Level = 'Info'
    )

    $color = switch ($Level) {
        'Warn' { 'Yellow' }
        'Ok' { 'Green' }
        default { 'Gray' }
    }

    Write-Host ("{0,-36} : {1}" -f $Key, $Value) -ForegroundColor $color
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AcerServices {
    $acerPatterns = @('Acer', 'Predator', 'Nitro', 'QuickAccess')
    $services = Get-Service | Where-Object {
        $n = $_.Name
        $d = $_.DisplayName
        foreach ($pattern in $acerPatterns) {
            if ($n -like "*$pattern*" -or $d -like "*$pattern*") {
                return $true
            }
        }
        return $false
    }

    return $services | Sort-Object DisplayName
}

function Get-CurrentPowerPlan {
    $raw = (powercfg /GETACTIVESCHEME) 2>$null
    if (-not $raw) {
        return [PSCustomObject]@{
            Guid = ''
            Name = 'Unknown'
        }
    }

    if ($raw -match 'Power Scheme GUID:\s+([a-fA-F0-9\-]+)\s+\((.+)\)') {
        return [PSCustomObject]@{
            Guid = $matches[1]
            Name = $matches[2]
        }
    }

    return [PSCustomObject]@{
        Guid = ''
        Name = $raw
    }
}

function Resolve-TargetPowerPlan {
    param([string]$SelectedProfile)

    $aliases = @{
        Balanced = 'SCHEME_BALANCED'
        BestPerformance = 'SCHEME_MIN'
        BatterySaver = 'SCHEME_MAX'
    }

    return $aliases[$SelectedProfile]
}

function Get-OptimizationPlan {
    param([string]$SelectedProfile)

    $steps = @()

    switch ($SelectedProfile) {
        'Balanced' {
            $steps += [PSCustomObject]@{ Name = 'Disk idle AC'; Command = 'powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_DISK DISKIDLE 10' }
            $steps += [PSCustomObject]@{ Name = 'Disk idle DC'; Command = 'powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_DISK DISKIDLE 5' }
            $steps += [PSCustomObject]@{ Name = 'Processor max AC'; Command = 'powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100' }
            $steps += [PSCustomObject]@{ Name = 'Processor max DC'; Command = 'powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 85' }
        }
        'BestPerformance' {
            # Aggressive AC-first profile for maximum sustained performance.
            $steps += [PSCustomObject]@{ Name = 'Disk idle AC'; Command = 'powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_DISK DISKIDLE 0' }
            $steps += [PSCustomObject]@{ Name = 'Sleep after AC'; Command = 'powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0' }
            $steps += [PSCustomObject]@{ Name = 'Display timeout AC'; Command = 'powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 0' }
            $steps += [PSCustomObject]@{ Name = 'Hibernate timeout AC'; Command = 'powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0' }
            $steps += [PSCustomObject]@{ Name = 'USB selective suspend AC'; Command = 'powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_USB USBSELECTIVE 0' }
            $steps += [PSCustomObject]@{ Name = 'PCIe link state AC'; Command = 'powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0' }
            $steps += [PSCustomObject]@{ Name = 'Processor min AC'; Command = 'powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100' }
            $steps += [PSCustomObject]@{ Name = 'Processor max AC'; Command = 'powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100' }
            $steps += [PSCustomObject]@{ Name = 'Processor boost AC'; Command = 'powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE 2' }
            $steps += [PSCustomObject]@{ Name = 'Processor autonomous mode AC'; Command = 'powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PERFAUTONOMOUSMODE 0' }
            $steps += [PSCustomObject]@{ Name = 'Processor energy preference AC'; Command = 'powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PERFEPP 0' }
        }
        'BatterySaver' {
            $steps += [PSCustomObject]@{ Name = 'Disk idle DC'; Command = 'powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_DISK DISKIDLE 3' }
            $steps += [PSCustomObject]@{ Name = 'Sleep after DC'; Command = 'powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 15' }
            $steps += [PSCustomObject]@{ Name = 'Processor max DC'; Command = 'powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 70' }
            $steps += [PSCustomObject]@{ Name = 'Processor boost DC'; Command = 'powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE 0' }
        }
    }

    $steps += [PSCustomObject]@{ Name = 'Apply active power scheme'; Command = 'powercfg /SETACTIVE SCHEME_CURRENT' }
    return $steps
}

function Invoke-Step {
    param(
        [string]$Name,
        [string]$Command,
        [switch]$WhatIfMode
    )

    if ($WhatIfMode) {
        Write-Item -Key ("Would run: " + $Name) -Value $Command
        return
    }

    try {
        Write-Item -Key ("Running: " + $Name) -Value $Command
        Invoke-Expression $Command | Out-Null
    }
    catch {
        Write-Item -Key ("Skipped: " + $Name) -Value $_.Exception.Message -Level 'Warn'
    }
}

function New-OptimizationBackup {
    param(
        [string]$SelectedProfile,
        [string]$BackupRootPath,
        [array]$PlannedSteps
    )

    $currentPlan = Get-CurrentPowerPlan
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $BackupRootPath ("backup-" + $timestamp)
    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null

    $powerFile = Join-Path $backupDir 'current-scheme.pow'
    if ($currentPlan.Guid) {
        Invoke-Expression ("powercfg /EXPORT `"$powerFile`" " + $currentPlan.Guid) | Out-Null
    }

    $manifest = [PSCustomObject]@{
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        profile = $SelectedProfile
        activePlanName = $currentPlan.Name
        activePlanGuid = $currentPlan.Guid
        backupPowerFile = $powerFile
        plannedCommands = $PlannedSteps | Select-Object -ExpandProperty Command
    }

    $manifestPath = Join-Path $backupDir 'manifest.json'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

    return $manifestPath
}

function Resolve-RollbackManifest {
    param(
        [string]$BackupRootPath,
        [string]$ManifestPath
    )

    if ($ManifestPath) {
        if (-not (Test-Path -Path $ManifestPath)) {
            throw "Rollback manifest not found: $ManifestPath"
        }
        return $ManifestPath
    }

    $latest = Get-ChildItem -Path $BackupRootPath -Filter manifest.json -Recurse -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $latest) {
        throw "No backup manifest found under $BackupRootPath"
    }

    return $latest.FullName
}

function Invoke-Analysis {
    param([string]$SelectedProfile)

    Write-Section 'Laptop Optimizer Analysis'

    Write-Item -Key 'Requested profile' -Value $SelectedProfile

    $plan = Get-CurrentPowerPlan
    Write-Item -Key 'Current power plan' -Value ("$($plan.Name) [$($plan.Guid)]")

    $isAdmin = Test-Admin
    Write-Item -Key 'Running as administrator' -Value $isAdmin -Level ($(if ($isAdmin) { 'Ok' } else { 'Warn' }))

    $acerServices = Get-AcerServices
    if ($acerServices.Count -gt 0) {
        $runningCount = ($acerServices | Where-Object { $_.Status -eq 'Running' }).Count
        Write-Item -Key 'Acer-related services found' -Value ("$($acerServices.Count) ($runningCount running)") -Level 'Ok'
    }
    else {
        Write-Item -Key 'Acer-related services found' -Value 'None detected (generic laptop mode)' -Level 'Warn'
    }

    Write-Section 'Planned Operations'
    $steps = Get-OptimizationPlan -SelectedProfile $SelectedProfile
    foreach ($step in $steps) {
        Write-Item -Key $step.Name -Value $step.Command
    }

    Write-Host "`nAnalysis complete. Use -Optimize to apply or -Optimize -WhatIfOnly for dry-run output." -ForegroundColor Cyan
}

function Invoke-Optimization {
    param(
        [string]$SelectedProfile,
        [switch]$WhatIfMode,
        [switch]$SkipVendorChecks,
        [string]$BackupRootPath
    )

    Write-Section 'Optimization Run'

    if (-not (Test-Admin)) {
        throw 'Optimization requires an elevated PowerShell session (Run as Administrator).'
    }

    if (-not $SkipVendorChecks) {
        $acerServices = Get-AcerServices
        if ($acerServices.Count -eq 0) {
            Write-Item -Key 'Acer guardrail' -Value 'No Acer services found; applying generic laptop-safe profile.' -Level 'Warn'
        }
        else {
            Write-Item -Key 'Acer guardrail' -Value 'Acer services detected; avoiding vendor-controlled fan/GPU changes.' -Level 'Ok'
        }
    }

    $steps = Get-OptimizationPlan -SelectedProfile $SelectedProfile
    $manifestPath = New-OptimizationBackup -SelectedProfile $SelectedProfile -BackupRootPath $BackupRootPath -PlannedSteps $steps
    Write-Item -Key 'Recovery backup manifest' -Value $manifestPath -Level 'Ok'

    $targetPlan = Resolve-TargetPowerPlan -SelectedProfile $SelectedProfile
    Invoke-Step -Name 'Switch active plan' -Command ("powercfg /SETACTIVE " + $targetPlan) -WhatIfMode:$WhatIfMode

    foreach ($step in $steps) {
        Invoke-Step -Name $step.Name -Command $step.Command -WhatIfMode:$WhatIfMode
    }

    Write-Host "`nOptimization complete. If anything regresses, run -Rollback to restore latest backup." -ForegroundColor Green
}

function Invoke-Rollback {
    param(
        [string]$BackupRootPath,
        [string]$ManifestPath,
        [switch]$WhatIfMode
    )

    Write-Section 'Rollback Run'

    if (-not (Test-Admin)) {
        throw 'Rollback requires an elevated PowerShell session (Run as Administrator).'
    }

    $resolvedManifest = Resolve-RollbackManifest -BackupRootPath $BackupRootPath -ManifestPath $ManifestPath
    $manifest = Get-Content -Path $resolvedManifest -Raw | ConvertFrom-Json
    Write-Item -Key 'Using manifest' -Value $resolvedManifest -Level 'Ok'

    if (-not (Test-Path -Path $manifest.backupPowerFile)) {
        throw "Backup power file missing: $($manifest.backupPowerFile)"
    }

    $importGuid = $manifest.activePlanGuid
    Invoke-Step -Name 'Import backup scheme' -Command ("powercfg /IMPORT `"$($manifest.backupPowerFile)`" " + $importGuid) -WhatIfMode:$WhatIfMode
    Invoke-Step -Name 'Re-activate backup scheme' -Command ("powercfg /SETACTIVE " + $importGuid) -WhatIfMode:$WhatIfMode

    Write-Host "`nRollback complete. You can rerun -Analyze to verify restored settings." -ForegroundColor Green
}

if (-not $Analyze -and -not $Optimize -and -not $Rollback) {
    $Analyze = $true
}

$selectedModes = @($Analyze, $Optimize, $Rollback) | Where-Object { $_ }
if ($selectedModes.Count -gt 1) {
    throw 'Select only one mode at a time: -Analyze, -Optimize, or -Rollback.'
}

if ($Analyze) {
    Invoke-Analysis -SelectedProfile $Profile
}

if ($Optimize) {
    Invoke-Optimization -SelectedProfile $Profile -WhatIfMode:$WhatIfOnly -SkipVendorChecks:$SkipAcerChecks -BackupRootPath $BackupRoot
}

if ($Rollback) {
    Invoke-Rollback -BackupRootPath $BackupRoot -ManifestPath $RollbackManifest -WhatIfMode:$WhatIfOnly
}
