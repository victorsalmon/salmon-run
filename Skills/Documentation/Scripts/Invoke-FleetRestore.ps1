<#
.SYNOPSIS
    Restore fleet state from a backup archive created by Invoke-FleetBackup.
.DESCRIPTION
    Extracts a previously created backup archive, verifies manifest checksums,
    restores Docker volume contents and config files, and validates the restored
    state.
.PARAMETER BackupFile
    Path to the backup archive (fleet-backup-*.tar.gz).
.PARAMETER DryRun
    If set, show what would be restored without actually doing it.
.PARAMETER Force
    Overwrite existing non-empty volumes (default: refuse).
.PARAMETER LogDir
    Directory for restore log output (default: Tasks/Logs/).
.EXAMPLE
    .\Invoke-FleetRestore.ps1 -BackupFile ~/intersite-backups/fleet-backup-20260620-a1b2c3d.tar.gz
.EXAMPLE
    .\Invoke-FleetRestore.ps1 -BackupFile <path> -DryRun
.EXAMPLE
    .\Invoke-FleetRestore.ps1 -BackupFile <path> -Force
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$BackupFile,
    [switch]$DryRun,
    [switch]$Force,
    [string]$LogDir = "Tasks/Logs"
)

$startTime = Get-Date
$logFile = Join-Path $LogDir "restore-$($startTime.ToString('yyyyMMdd')).log"

$null = New-Item -ItemType Directory -Path $LogDir -Force

function Write-RestoreLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

Write-RestoreLog "Starting fleet restore from $BackupFile"

# ---- Validate backup file ----
if (-not (Test-Path $BackupFile)) {
    Write-RestoreLog "Backup file not found: $BackupFile" "ERROR"
    throw "Backup file not found: $BackupFile"
}

$backupItem = Get-Item $BackupFile
$extractDir = Join-Path ([System.IO.Path]::GetTempPath()) ".fleet-restore-$($startTime.Ticks)"
$null = New-Item -ItemType Directory -Path $extractDir -Force

try {
    # ---- Extract archive ----
    Write-RestoreLog "Extracting backup archive to $extractDir"
    if ($DryRun) {
        Write-RestoreLog "[DRY-RUN] Would extract $BackupFile to $extractDir"
    } else {
        $hostVolName = "restore-tmp-$($startTime.Ticks)"
        try {
            & docker volume create $hostVolName 2>>$logFile | Out-Null
            & docker run --rm -v "${hostVolName}:/data" -v "$([System.IO.Path]::GetDirectoryName($backupItem.FullName)):/backup" alpine tar xzf "/backup/$($backupItem.Name)" -C /data 2>>$logFile
            if ($LASTEXITCODE -ne 0) {
                throw "Extraction exited with code $LASTEXITCODE"
            }
            & docker run --rm -v "${hostVolName}:/data" -v "${extractDir}:/extract" alpine sh -c "cp -a /data/. /extract/" 2>>$logFile
            & docker volume rm $hostVolName 2>>$logFile | Out-Null
        } catch {
            & docker volume rm $hostVolName -f 2>>$null | Out-Null
            throw $_
        }
        Write-RestoreLog "Archive extracted to $extractDir"
    }

    # ---- Verify manifest ----
    $manifestPath = Join-Path $extractDir "MANIFEST.txt"
    if (-not (Test-Path $manifestPath)) {
        Write-RestoreLog "MANIFEST.txt not found in backup archive" "ERROR"
        throw "Corrupt backup: no MANIFEST.txt"
    }

    Write-RestoreLog "Verifying manifest checksums"
    $verificationErrors = @()

    $manifestContent = Get-Content -Path $manifestPath
    $fileEntries = $manifestContent | Where-Object { $_ -match '^[A-F0-9]{64}\s+\d+\s+(.+)$' }

    $expectedCount = 0
    $matchCount = 0
    foreach ($entry in $fileEntries) {
        $expectedCount++
        if ($DryRun) { continue }
        $parts = $entry -split '\s+', 3
        $expectedHash = $parts[0]
        $expectedSize = [long]$parts[1]
        $relativePath = $parts[2]
        $fullPath = Join-Path $extractDir $relativePath

        if (-not (Test-Path $fullPath)) {
            $verificationErrors += "Missing: $relativePath"
            Write-RestoreLog "Verification failed: $relativePath not found" "WARN"
            continue
        }

        $actualHash = (Get-FileHash -Path $fullPath -Algorithm SHA256).Hash
        if ($actualHash -ne $expectedHash) {
            $verificationErrors += "Hash mismatch: $relativePath (expected $expectedHash, got $actualHash)"
            Write-RestoreLog "Hash mismatch: $relativePath" "WARN"
        } else {
            $matchCount++
        }
    }

    if ($verificationErrors.Count -gt 0) {
        Write-RestoreLog "$($verificationErrors.Count) verification error(s) found" "WARN"
        Write-RestoreLog "Proceeding with restore despite verification errors" "WARN"
    }

    Write-RestoreLog "Manifest verified: $matchCount/$expectedCount files OK"

    # ---- Restore Docker volumes ----
    $volumeTarballs = Get-ChildItem -Path $extractDir -Filter "*.tar.gz" | Where-Object { $_.Name -ne ($backupItem.Name -replace '^.*/', '') -and $_.Name -ne "MANIFEST.txt" }
    foreach ($tarball in $volumeTarballs) {
        $volName = [System.IO.Path]::GetFileNameWithoutExtension($tarball.Name)
        if ($volName.EndsWith(".tar")) {
            $volName = [System.IO.Path]::GetFileNameWithoutExtension($volName)
        }
        Write-RestoreLog "Processing volume $volName"

        if ($DryRun) {
            Write-RestoreLog "[DRY-RUN] Would restore volume $volName from $($tarball.Name)"
            continue
        }

        # Check if volume already exists
        $existingVol = & docker volume ls --format "{{.Name}}" 2>$null | Where-Object { $_.Trim() -eq $volName }
        if ($existingVol) {
            if (-not $Force) {
                Write-RestoreLog "Volume $volName already exists. Use -Force to overwrite." "WARN"
                continue
            }
            Write-RestoreLog "Removing existing volume $volName (Force)"
            & docker volume rm $volName 2>>$logFile | Out-Null
        }

        & docker volume create $volName 2>>$logFile | Out-Null
        Write-RestoreLog "Restoring $volName from $($tarball.Name)"
        try {
            & docker run --rm -v "${volName}:/data" -v "${extractDir}:/backup" alpine tar xzf "/backup/$($tarball.Name)" -C /data 2>>$logFile
            if ($LASTEXITCODE -eq 0) {
                Write-RestoreLog "Volume $volName restored successfully"
            } else {
                Write-RestoreLog "Volume $volName restore exited with code $LASTEXITCODE" "ERROR"
            }
        } catch {
            Write-RestoreLog "Volume $volName restore failed: $_" "ERROR"
        }
    }

    # ---- Restore config files ----
    $configMappings = @(
        @{ Source = ".ORCHESTRATOR";       Dest = Join-Path $env:USERPROFILE ".ORCHESTRATOR" }
        @{ Source = ".aws";            Dest = Join-Path $env:USERPROFILE ".aws" }
        @{ Source = "Tasks-Logs";      Dest = "Tasks/Logs" }
        @{ Source = "Tasks-Complete";  Dest = "Tasks/Complete" }
        @{ Source = "Tasks-Handoff";   Dest = "Tasks/Handoff" }
        @{ Source = "install.json";    Dest = "install.json" }
    )

    foreach ($mapping in $configMappings) {
        $sourcePath = Join-Path $extractDir $mapping.Source
        if (-not (Test-Path $sourcePath)) {
            Write-RestoreLog "Config source $($mapping.Source) not found in backup, skipping" "WARN"
            continue
        }

        $destPath = $mapping.Dest
        if (-not ([System.IO.Path]::IsPathRooted($destPath))) {
            $destPath = Join-Path $PWD $destPath
        }

        if ($DryRun) {
            Write-RestoreLog "[DRY-RUN] Would restore $($mapping.Source) to $destPath"
            continue
        }

        if (Test-Path -Path $sourcePath -PathType Container) {
            $null = New-Item -ItemType Directory -Path $destPath -Force
            & robocopy $sourcePath $destPath /E /NJH /NJS /NP 2>$null | Out-Null
        } else {
            $parentDir = Split-Path $destPath -Parent
            $null = New-Item -ItemType Directory -Path $parentDir -Force
            Copy-Item -Path $sourcePath -Destination $destPath -Force
        }
        Write-RestoreLog "Restored $($mapping.Source) to $destPath"
    }

    # ---- Verify restored state ----
    Write-RestoreLog "Verifying restored state"

    # Check install.json is valid JSON
    $installJsonPath = Join-Path $PWD "install.json"
    if (Test-Path $installJsonPath) {
        try {
            $parsed = Get-Content $installJsonPath -Raw | ConvertFrom-Json
            if ($parsed.version) {
                Write-RestoreLog "install.json is valid JSON (version: $($parsed.version))"
            } else {
                Write-RestoreLog "install.json parsed but missing version field" "WARN"
            }
        } catch {
            Write-RestoreLog "install.json is not valid JSON: $_" "ERROR"
        }
    } else {
        Write-RestoreLog "install.json not found after restore" "WARN"
    }

    # Spot-check volumes for expected files
    $spotCheckVolumes = @(
        @{ NamePattern = "*agent_config*"; ExpectedFiles = @("soul.md", "identity.md") }
    )

    $allVolumes = & docker volume ls --format "{{.Name}}" 2>$null
    foreach ($check in $spotCheckVolumes) {
        $matchedVolumes = $allVolumes | Where-Object { $_ -like $check.NamePattern }
        foreach ($vol in $matchedVolumes) {
            $vol = $vol.Trim()
            if ([string]::IsNullOrWhiteSpace($vol)) { continue }
            foreach ($expectedFile in $check.ExpectedFiles) {
                if ($DryRun) {
                    Write-RestoreLog "[DRY-RUN] Would check $vol for $expectedFile"
                    continue
                }
                try {
                    $result = & docker run --rm -v "${vol}:/data" alpine sh -c "test -f /data/$expectedFile && echo 'EXISTS' || echo 'MISSING'" 2>$null
                    if ($result.Trim() -eq "EXISTS") {
                        Write-RestoreLog "Spot-check: $vol contains $expectedFile"
                    } else {
                        Write-RestoreLog "Spot-check: $vol missing $expectedFile" "WARN"
                    }
                } catch {
                    Write-RestoreLog "Spot-check failed for $($vol): $_" "WARN"
                }
            }
        }
    }
} finally {
    # Cleanup
    if (Test-Path $extractDir) {
        Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
Write-RestoreLog "Fleet restore completed in ${elapsed}s"
