<#
.SYNOPSIS
    Copies multiple files into a Docker volume through a single long-lived container.
.DESCRIPTION
    Creates one long-lived alpine container with the target volume mounted, copies
    all files via docker cp, runs optional post-copy exec commands, then destroys
    the container. Replaces the per-file container pattern with a batch operation.
.PARAMETER VolumeName
    Name of the Docker volume to seed.
.PARAMETER Files
    Array of hashtables: @{ Source = "hostpath"; Target = "volpath" }
.PARAMETER ExecCommands
    Optional array of shell commands to run inside the container after copy.
.PARAMETER Image
    Image to use (default: alpine:latest '" faster than debian images).
.PARAMETER Description
    Human-readable label for logging.
.OUTPUTS
    $true if all copies and exec commands succeeded, $false otherwise.
#>
function Copy-FilesToVolume {
    [OutputType([bool])]
    param(
        [string]$VolumeName,
        [hashtable[]]$Files,
        [string[]]$ExecCommands,
        [string]$Image = "alpine:latest",
        [string]$Description
    )
    Write-SetupLog "Batch seeding ${Description}: ${VolumeName} ($($Files.Count) files)"

    $Container = (docker run -d --rm -v "${VolumeName}:/target" "$Image" /bin/sh -c "tail -f /dev/null" 2>$null).Trim()
    if ([string]::IsNullOrWhiteSpace($Container)) {
        Write-Information -MessageData "  [FAIL] Could not create batch container for $Description" -Tags "ERROR"
            Write-SetupLog "Batch seeding FAILED for $Description - could not create container" -Level ERROR
        return $false
    }

    try {
        $AllOk = $true
        foreach ($File in $Files) {
            $CpResult = Invoke-NativeCommand { docker cp "$($File.Source)" "${Container}:/target/$($File.Target)" 2>&1 }
            if (-not $CpResult.Success) {
                Write-SetupLog "docker cp failed for $($File.Source) -> $($File.Target)" -Level WARN
                $AllOk = $false
            }
        }

        foreach ($Cmd in $ExecCommands) {
            $ExecResult = Invoke-NativeCommand { docker exec $Container /bin/sh -c "$Cmd" 2>&1 }
            if (-not $ExecResult.Success) {
                Write-SetupLog "docker exec failed: $Cmd" -Level WARN
                $AllOk = $false
            }
        }

        if ($AllOk) {
            Write-Information -MessageData "  [OK] Batch seeded: $Description ($($Files.Count) files)" -Tags "INFO"
            Write-SetupLog "Batch seeded OK: $Description"
        }
        else {
            Write-Information -MessageData "  [WARN] Batch seeded with errors: $Description" -Tags "WARN"
            Write-SetupLog "Batch seeded with warnings: $Description" -Level WARN
        }
        return $AllOk
    }
    catch {
        Write-Information -MessageData "  [FAIL] Error batch seeding $Description : $($_.Exception.Message)" -Tags "ERROR"
        Write-SetupLog "Batch seeding ERROR for $Description : $($_.Exception.Message)" -Level ERROR
        return $false
    }
    finally {
        $null = docker rm -f $Container 2>$null
    }
}


