# Laptop PC Optimizer (Acer-aware)

PowerShell optimizer tuned for laptops (including Acer Predator Helios-class systems) with an **analysis-first workflow**, aggressive `BestPerformance` options, and built-in **recovery/rollback**.

## Goals

- Respect OEM restrictions (PredatorSense and Acer services keep fan/GPU controls).
- Focus on `powercfg` policy values that are safe to automate.
- Provide a rollback path before changing anything.

## Script

- `laptop_optimizer.ps1`

## Modes

- `-Analyze` (default): inspect current state and show planned commands.
- `-Optimize`: apply selected profile and create backup manifest + exported power scheme.
- `-Rollback`: restore from latest backup (or specific manifest).

## Profiles

- `Balanced`
- `BestPerformance` (**aggressive AC-focused tuning**)
- `BatterySaver`

## BestPerformance includes

- Disable disk idle timer on AC
- Disable sleep timeout on AC
- Disable display timeout on AC
- Disable hibernate timeout on AC
- Disable USB selective suspend on AC
- Disable PCIe link state power management on AC
- Force CPU min/max to 100% on AC
- Enable aggressive CPU boost mode
- Disable autonomous CPU energy mode and set EPP to 0

> Expect higher fan noise, heat, and power draw in this mode.

## Usage

### Analyze (default)

```powershell
.\laptop_optimizer.ps1
```

### Dry-run aggressive optimization

```powershell
.\laptop_optimizer.ps1 -Optimize -Profile BestPerformance -WhatIfOnly
```

### Apply optimization

```powershell
.\laptop_optimizer.ps1 -Optimize -Profile BestPerformance
```

### Roll back latest backup

```powershell
.\laptop_optimizer.ps1 -Rollback
```

### Roll back using specific manifest

```powershell
.\laptop_optimizer.ps1 -Rollback -RollbackManifest .\optimizer-backups\backup-20260421-010203\manifest.json
```

## Recovery details

Each optimization run saves:

- `manifest.json` (profile, timestamp, active scheme GUID, commands)
- `current-scheme.pow` (exported active scheme)

Default backup root is `./optimizer-backups` (override with `-BackupRoot`).

## Important notes for Acer Predator users

- Keep PredatorSense installed and updated.
- Let Acer software own fan profiles, turbo modes, and mux/GPU behavior.
- This script intentionally does not edit Acer services.
