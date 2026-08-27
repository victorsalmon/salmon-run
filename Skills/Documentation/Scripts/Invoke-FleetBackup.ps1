<#
.SYNOPSIS
    Back up all fleet Docker volumes, agent memory, session state, and workspace data.
.DESCRIPTION
    Identifies all Docker named volumes in the interclaw fleet stack, exports each
    to a tarball, and bundles them with config files into a single backup archive
    with a SHA256 manifest.
.PARAMETER OutputDir
    Directory to write the backup archive (default: ~/intersite-backups/).
.PARAMETER Compress
    If true (default), produces a single .tar.gz of all contents.
.PARAMETER LogDir
    Directory for backup log output (default: Tasks/Logs/).
.EXAMPLE
    .\Invoke-FleetBackup.ps1
.EXAMPLE
    .\Invoke-FleetBackup.ps1 -OutputDir D:\backups -Compress:$false
#>

param(
    [string]$OutputDir = (Join-Path $env:USERPROFILE "intersite-backups"),
    [switch]$Compress = $true,
    [string]$LogDir = "Tasks/Logs"
)

$startTime = Get-Date
$dateStamp = $startTime.ToString("yyyyMMdd-HHmmss")
$logFile = Join-Path $LogDir "backup-$($startTime.ToString('yyyyMMdd')).log"

$null = New-Item -ItemType Directory -Path $LogDir -Force
$null = New-Item -ItemType Directory -Path $OutputDir -Force

function Write-BackupLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

Write-BackupLog "Starting fleet backup"

# ---- Get git short hash ----
$gitHash = "unknown"
try {
    $gitHash = (& git rev-parse --short HEAD 2>$null) ?? "unknown"
    $gitHash = $gitHash.Trim()
} catch {
    Write-BackupLog "Could not determine git hash, using 'unknown'" "WARN"
}

$backupName = "fleet-backup-$dateStamp-$gitHash"
$workDir = Join-Path $OutputDir ".$backupName.work"
$null = New-Item -ItemType Directory -Path $workDir -Force

$manifest = @()

# ---- 1. Back up Docker volumes ----
Write-BackupLog "Discovering Docker volumes with label com.docker.stack.namespace=interclaw"

try {
    $volumeLines = & docker volume ls --filter label=com.docker.stack.namespace=interclaw --format "{{.Name}}" 2>$null
} catch {
    Write-BackupLog "Docker not available or swarm not running: $_" "ERROR"
    $volumeLines = @()
}

if (-not $volumeLines -or $volumeLines.Count -eq 0) {
    Write-BackupLog "No interclaw volumes found (continuing with config backup)" "WARN"
} else {
    foreach ($vol in $volumeLines) {
        $vol = $vol.Trim()
        if ([string]::IsNullOrWhiteSpace($vol)) { continue }
        $volTarball = "$vol.tar.gz"
        $volTarballPath = Join-Path $workDir $volTarball
        Write-BackupLog "Exporting volume $vol to $volTarball"
        try {
            & docker run --rm -v "${vol}:/data" -v "${workDir}:/backup" alpine tar czf "/backup/$volTarball" -C /data . 2>>$logFile
            if ($LASTEXITCODE -eq 0) {
                Write-BackupLog "Volume $vol exported successfully"
            } else {
                Write-BackupLog "Volume $vol export exited with code $LASTEXITCODE" "ERROR"
            }
        } catch {
            Write-BackupLog "Volume $vol export failed: $_" "ERROR"
        }
    }
}

# ---- 2. Back up config files ----
$configItems = @(
    @{ Path = Join-Path $env:USERPROFILE ".ORCHESTRATOR";         Target = ".ORCHESTRATOR" }
    @{ Path = Join-Path $env:USERPROFILE ".aws";              Target = ".aws" }
    @{ Path = "Tasks\Logs";                                   Target = "Tasks-Logs" }
    @{ Path = "Tasks\Complete";                               Target = "Tasks-Complete" }
    @{ Path = "Tasks\Handoff";                                Target = "Tasks-Handoff" }
    @{ Path = "install.json";                                 Target = "install.json" }
)

foreach ($item in $configItems) {
    $fullPath = $item.Path
    if (-not ([System.IO.Path]::IsPathRooted($fullPath))) {
        $fullPath = Join-Path $PWD $fullPath
    }
    if (Test-Path $fullPath) {
        $target = Join-Path $workDir $item.Target
        if (($item.Target -eq "install.json") -or ($item.Target -eq ".ORCHESTRATOR") -or ($item.Target -eq ".aws")) {
            if (Test-Path -Path $fullPath -PathType Container) {
                & robocopy $fullPath $target /E /NJH /NJS /NP 2>$null | Out-Null
            } else {
                Copy-Item -Path $fullPath -Destination $target -Force
            }
        } else {
            & robocopy $fullPath $target /E /NJH /NJS /NP 2>$null | Out-Null
        }
        Write-BackupLog "Copied $fullPath to $target"
    } else {
        Write-BackupLog "Config path $fullPath not found, skipping" "WARN"
    }
}

# ---- 3. Generate manifest ----
Write-BackupLog "Generating manifest with SHA256 checksums"

$manifestLines = @()
$manifestLines += "# Fleet Backup Manifest"
$manifestLines += "# Backup name: $backupName"
$manifestLines += "# Date: $((Get-Date).ToUniversalTime().ToString('o'))"
$manifestLines += "# Git hash: $gitHash"
$manifestLines += "#"

Get-ChildItem -Path $workDir -Recurse -File | ForEach-Object {
    $relativePath = $_.FullName.Substring($workDir.Length + 1)
    $hash = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash
    $size = $_.Length
    $manifestLines += "$hash  $size  $relativePath"
    $manifest += @{
        Path = $relativePath
        Hash = $hash
        Size = $size
    }
}

$manifestContent = $manifestLines -join "`r`n"
$manifestPath = Join-Path $workDir "MANIFEST.txt"
$manifestContent | Out-File -FilePath $manifestPath -Encoding utf8
Write-BackupLog "Manifest written to $manifestPath"

# ---- 4. Produce final archive ----
if ($Compress) {
    $archiveName = "$backupName.tar.gz"
    $archivePath = Join-Path $OutputDir $archiveName
    Write-BackupLog "Creating compressed archive $archivePath"
    try {
        & docker run --rm -v "${workDir}:/source" -v "${OutputDir}:/out" alpine tar czf "/out/$archiveName" -C /source . 2>>$logFile
        if ($LASTEXITCODE -eq 0) {
            Write-BackupLog "Compressed archive created: $archivePath"
        } else {
            Write-BackupLog "Compression exited with code $LASTEXITCODE" "ERROR"
        }
    } catch {
        Write-BackupLog "Compression failed: $_" "ERROR"
    }
} else {
    Write-BackupLog "Compress=false; final archive not created, backup contents are in $workDir"
}

# ---- Cleanup work dir ----
Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
Write-BackupLog "Fleet backup completed in ${elapsed}s"

# ---- Output result path ----
if ($Compress) {
    Get-Item $archivePath | Select-Object FullName, Length, LastWriteTime
} else {
    Write-Output "Backup contents (not compressed): $workDir"
    Write-Output "Manifest location: $manifestPath"
}
