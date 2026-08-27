# Uses skills.json (full manifest) for installation metadata.
# For agent-facing discovery, use skills-index.json (lightweight, 26 KB).

param(
    [switch]$WhatIf,
    [string]$TargetDir,
    [switch]$Symlink
)

$scriptName = "Install-Skills.ps1"
$logPrefix = "[$scriptName]"

# Default TargetDir if not provided
if (-not $TargetDir) {
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $TargetDir = Join-Path $homeDir ".opencode\skills"
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$timestamp $logPrefix $Message"
}

$registryPath = Join-Path $PSScriptRoot "..\..\Skills\skills.json"
if (-not (Test-Path $registryPath)) {
    Write-Error "skills.json not found at $registryPath"
    exit 1
}

$registry = Get-Content $registryPath -Raw | ConvertFrom-Json
Write-Log "Loaded $($registry.Count) skills from registry"

if ($WhatIf) {
    Write-Log "=== DRY RUN (WhatIf) ==="
    Write-Log "Would install to: $TargetDir"
    Write-Log "Symlink mode: $($Symlink.IsPresent)"
    Write-Log ""
    Write-Log "Skills by container:"
    $registry | Group-Object container | ForEach-Object {
        Write-Log "  $($_.Name): $($_.Count) skills"
    }
    Write-Log ""
    Write-Log "Skills with stale=true: $(($registry | Where-Object { $_.stale -eq $true }).Count)"
    if ($Symlink) {
        Write-Log "Would re-create symlinks in: $TargetDir"
    } else {
        Write-Log "Would copy files to: $TargetDir"
    }
    return
}

$null = New-Item -ItemType Directory -Path $TargetDir -Force -ErrorAction SilentlyContinue
$installed = 0
$skipped = 0
$errors = @()

foreach ($skill in $registry) {
    if ($skill.stale -eq $true) {
        Write-Log "SKIP stale: $($skill.name)"
        $skipped++
        continue
    }

    # Flavor-based filtering
    # "ORCHESTRATOR" flavor with "persona" type → skip (deployed into Docker containers)
    if ($skill.flavor -eq "ORCHESTRATOR" -and $skill.type -eq "persona") {
        Write-Log "SKIP persona (container-deployed): $($skill.name)"
        $skipped++
        continue
    }

    $sourcePath = Join-Path $PSScriptRoot "..\..\$($skill.path)"
    $sourcePath = Resolve-Path $sourcePath -ErrorAction SilentlyContinue

    if (-not $sourcePath) {
        Write-Log "ERROR source not found: $($skill.path)"
        $errors += $skill.path
        continue
    }

    # Shared flavor → subdirectory
    if ($skill.flavor -eq "shared") {
        $targetSubdir = Join-Path $TargetDir "shared"
        $null = New-Item -ItemType Directory -Path $targetSubdir -Force -ErrorAction SilentlyContinue
        $targetFile = Join-Path $targetSubdir "$($skill.name).md"
    } else {
        $targetFile = Join-Path $TargetDir "$($skill.name).md"
    }

    if ($Symlink) {
        $relativeSource = Resolve-Path $sourcePath -Relative
        try {
            if (Test-Path $targetFile) { Remove-Item $targetFile -Force }
            New-Item -ItemType SymbolicLink -Path $targetFile -Target $sourcePath -Force | Out-Null
            Write-Log "LINK $($skill.name) → $relativeSource"
        } catch {
            Write-Log "ERROR linking $($skill.name): $_"
            $errors += $skill.name
        }
    } else {
        try {
            Copy-Item -LiteralPath $sourcePath -Destination $targetFile -Force
            Write-Log "COPY $($skill.name) → $targetFile"
        } catch {
            Write-Log "ERROR copying $($skill.name): $_"
            $errors += $skill.name
        }
    }
    $installed++
}

Write-Log ""
Write-Log "=== Summary ==="
Write-Log "  Installed: $installed"
Write-Log "  Skipped (stale): $skipped"
if ($errors.Count -gt 0) {
    Write-Log "  Errors: $($errors.Count)"
    $errors | ForEach-Object { Write-Log "    - $_" }
} else {
    Write-Log "  Errors: 0"
}
