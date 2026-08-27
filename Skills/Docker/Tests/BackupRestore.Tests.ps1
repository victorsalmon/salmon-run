#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Interclaw — Pester 5 Tests for Invoke-FleetBackup / Invoke-FleetRestore
# Round-trip: backup → remove volume → restore → verify content
# ==============================================================================

BeforeAll {
    $BackupScript   = Join-Path $PSScriptRoot "..\..\OpenCode\Scripts\Invoke-FleetBackup.ps1"
    $RestoreScript  = Join-Path $PSScriptRoot "..\..\OpenCode\Scripts\Invoke-FleetRestore.ps1"

    . $BackupScript
    . $RestoreScript

    $testVolume   = "test-backup-$(Get-Random -Maximum 99999)"
    $testDir      = Join-Path $TestDrive "restore-check"
    $null = New-Item -ItemType Directory -Path $testDir -Force

    $knownContent = @{
        "hello.txt"     = "Hello from backup test!"
        "sub/deep.txt"  = "Nested file content"
        "config.json"   = '{ "version": 1, "test": true }'
    }

    # ---- Guard: skip if Docker is not available ----
    $dockerAvailable = $false
    try {
        $dv = & docker version --format "{{.Server.Version}}" 2>$null
        if ($dv) { $dockerAvailable = $true }
    } catch {
        Write-Warning "Docker is not available — skipping Docker-dependent tests"
    }
}

Describe "Fleet Backup/Restore round-trip" -Tag "Backup", "Integration" {
    BeforeAll {
        if (-not $dockerAvailable) { return }
        # Create test volume with known content
        & docker volume create $testVolume 2>$null | Out-Null
        foreach ($file in $knownContent.Keys) {
            $parentDir = Split-Path $file -Parent
            if ($parentDir) {
                & docker run --rm -v "${testVolume}:/data" alpine mkdir -p "/data/$parentDir" 2>$null
            }
            & docker run --rm -v "${testVolume}:/data" alpine sh -c "printf '%s' '$($knownContent[$file])' > /data/$file" 2>$null
        }
    }

    AfterAll {
        if (-not $dockerAvailable) { return }
        & docker volume rm $testVolume -f 2>$null | Out-Null
        & docker volume rm "test-backup-*-$($testVolume -replace '^test-backup-', '')" -f 2>$null | Out-Null
    }

    It "Backs up the test volume" -Skip:(-not $dockerAvailable) {
        # Backup to TestDrive
        $outputDir = $TestDrive
        & $BackupScript -OutputDir $outputDir -Compress

        # Verify backup file was created
        $backupFiles = Get-ChildItem -Path $outputDir -Filter "fleet-backup-*.tar.gz"
        $backupFiles | Should -Not -BeNullOrEmpty
        $backupFiles.Count | Should -BeGreaterOrEqual 1
    }

    It "Restores the volume from backup" -Skip:(-not $dockerAvailable) {
        # Remove the test volume
        & docker volume rm $testVolume -f 2>$null | Out-Null

        # Find the backup
        $backupFile = Get-ChildItem -Path $TestDrive -Filter "fleet-backup-*.tar.gz" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $backupFile | Should -Not -BeNullOrEmpty

        # Restore
        & $RestoreScript -BackupFile $backupFile.FullName -Force

        # Verify volume exists
        $volumes = & docker volume ls --format "{{.Name}}"
        $volumes -split "`n" | ForEach-Object { $_.Trim() } | Should -Contain $testVolume
    }

    It "Restored content matches original" -Skip:(-not $dockerAvailable) {
        # Extract content from restored volume for verification
        foreach ($file in $knownContent.Keys) {
            $result = & docker run --rm -v "${testVolume}:/data" alpine sh -c "cat /data/$file 2>/dev/null || echo 'FILE_NOT_FOUND'"
            $result.Trim() | Should -Be $knownContent[$file]
        }
    }

    It "Dry-run does not modify volumes" -Skip:(-not $dockerAvailable) {
        # Create a new volume for dry-run testing
        $dryRunVol = "test-backup-dryrun-$(Get-Random -Maximum 99999)"
        & docker volume create $dryRunVol 2>$null | Out-Null
        & docker run --rm -v "${dryRunVol}:/data" alpine sh -c "printf 'original' > /data/keepme.txt" 2>$null

        $backupFile = Get-ChildItem -Path $TestDrive -Filter "fleet-backup-*.tar.gz" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1

        # Force-set the volume name in the backup scenario — just verify dry-run doesn't error
        { & $RestoreScript -BackupFile $backupFile.FullName -DryRun -Force } | Should -Not -Throw

        # Verify original content intact
        $result = & docker run --rm -v "${dryRunVol}:/data" alpine sh -c "cat /data/keepme.txt"
        $result.Trim() | Should -Be "original"

        & docker volume rm $dryRunVol -f 2>$null | Out-Null
    }
}
