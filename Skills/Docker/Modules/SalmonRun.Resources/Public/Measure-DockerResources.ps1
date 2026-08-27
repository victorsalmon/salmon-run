<#
.SYNOPSIS
    Measures Docker host memory and disk resources with retry logic.
.DESCRIPTION
    Queries docker info for total memory (MemTotal) with 3 retries and a 25s
    timeout per attempt. Optionally checks free disk via an Alpine container.
    Falls back to defaults (16GB RAM, 2x estimate disk) on failure. Caches
    result in $script:DockerResourcesCache. Sets env vars DOCKER_TOTAL_MEMORY_GB
    and DOCKER_DISK_AVAILABLE_GB for downstream consumers.
.PARAMETER AgentCount
    Number of fleet agents to reserve memory for (4GB each).
.PARAMETER InstallFleet
    Whether to include Fleet memory reservation. Default "true".
.PARAMETER InstallTailscale
    Whether to include Tailscale reservation. Default "false".
.PARAMETER InstallBrowserless
    Whether to include Browserless reservation. Default "false".
.PARAMETER IncludeDiskCheck
    If set, runs an Alpine container to measure free disk.
.OUTPUTS
    PSCustomObject with TotalGB, AvailableGB, and AvailableDiskGB properties.
#>
function Measure-DockerResources {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [int]$AgentCount = 0,
        [string]$InstallFleet = "true",
        [string]$InstallTailscale = "false",
        [string]$InstallBrowserless = "false",
        [switch]$IncludeDiskCheck
    )

    try {
    Write-Information -MessageData "`n[RESOURCES] Profiling Docker memory..." -Tags "INFO"

    $DockerMemBytes = 0
    if ($env:DOCKER_INFO_MEMTOTAL_CACHE -match '^\d+$') {
        $DockerMemBytes = [long]$env:DOCKER_INFO_MEMTOTAL_CACHE
        Write-SetupLog "Measure-DockerResources: using warm MemTotal cache: ${DockerMemBytes} bytes" -Level INFO
        Remove-Item -Path "Env:\DOCKER_INFO_MEMTOTAL_CACHE" -ErrorAction SilentlyContinue
    }
    if ($DockerMemBytes -eq 0) {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Write-SetupLog "Measure-DockerResources: Attempt $attempt/3 querying docker info MemTotal (timeout: 25s)" -Level INFO
            $job = Start-Job -ScriptBlock { docker info --format '{{.MemTotal}}' 2>$null }
            $null = Wait-Job $job -Timeout 25
            $output = Receive-Job $job
            Remove-Job $job -ErrorAction SilentlyContinue
            $trimmed = "$output".Trim()
            if ($trimmed -match '^\d+$') {
                $DockerMemBytes = [long]$trimmed
                break
            }
            Write-SetupLog "Attempt $attempt/3: received '$((($output -replace '\s+',' ').Substring(0, [math]::Min(40, ($output -replace '\s+',' ').Length))))' - not a valid MemTotal integer" -Level WARN
            if ($attempt -lt 3) {
                Write-SetupLog "Retry $attempt/3: docker info unresponsive, waiting..." -Level WARN
                Start-Sleep -Seconds (Get-BackoffDelay -Attempt $attempt -Schedule @(5, 10, 15) -JitterFraction 0.25)
            }
        }
    }
    if ($DockerMemBytes -eq 0) {
        Write-Information -MessageData "  [WARN] Could not read Docker memory (retried 3x). Using default 16GB." -Tags "WARN"
        Write-Information -MessageData "  [HINT] Ensure Docker Desktop is running and WSL2 is responsive." -Tags "WARN"
        Write-SetupLog "Measure-DockerResources: docker info failed after 3 retries, defaulting to 16GB" -Level WARN
        $DockerTotalGB = 16
    } else {
        $DockerTotalGB = [math]::Floor($DockerMemBytes / 1GB)
        if ($DockerTotalGB -lt 4) {
            Write-Information -MessageData "  [WARN] Docker MemTotal $DockerTotalGB GB too low. Assuming 16GB." -Tags "WARN"
            $DockerTotalGB = 16
        }
        Write-Information -MessageData "  Docker total memory: ${DockerTotalGB}GB" -Tags "INFO"
    }

        $FleetReservedGB = $AgentCount * 4

        if ($InstallFleet -eq "true") {
            $FleetMem = if ($env:FLEET_MEMORY_LIMIT -match '^(\d+)G$') { [int]$Matches[1] } else { 1 }
            $FleetReservedGB += $FleetMem
            Write-Information -MessageData "  Fleet memory: ${FleetMem}GB" -Tags "INFO"
        }
        if ($InstallTailscale -eq "true") { $FleetReservedGB += 1 }
        if ($InstallBrowserless -eq "true") { $FleetReservedGB += 0.5 }

        $AvailableGB = $DockerTotalGB - $FleetReservedGB
        if ($AvailableGB -lt 1) { $AvailableGB = 1 }

        $AvailableDiskGB = 0
        if ($IncludeDiskCheck) {
            $DiskResult = $false
            for ($i = 0; $i -lt 3; $i++) {
                $djob = Start-Job -ScriptBlock {
                    $out = docker run --rm alpine df -k / 2>$null | Select-Object -Last 1
                    if ($out -match '\s+(\d+)\s+\d+%\s+/$') {
                        return [math]::Floor([long]$Matches[1] / 1024 / 1024)
                    }
                    return $null
                }
                $djob | Wait-Job -Timeout 45 | Out-Null
                if ($djob.State -eq 'Completed') {
                    $doutput = Receive-Job $djob
                    Remove-Job $djob -Force -ErrorAction SilentlyContinue
                    if ($null -ne $doutput -and $doutput -gt 0) {
                        $AvailableDiskGB = $doutput
                        $DiskResult = $true
                        break
                    }
                } else {
                    Stop-Job $djob -ErrorAction SilentlyContinue
                    Remove-Job $djob -Force -ErrorAction SilentlyContinue
                }
                if ($i -lt 2) { Start-Sleep -Seconds (Get-BackoffDelay -Attempt ($i + 1) -Schedule @(3, 5, 10) -JitterFraction 0.25) }
            }
        }

        if (($null -eq $AvailableDiskGB -or $AvailableDiskGB -le 0) -and $DockerTotalGB -gt 0) {
            $AvailableDiskGB = $DockerTotalGB * 2
            if ($IncludeDiskCheck) { Write-Information -MessageData "  [WARN] Could not read Docker disk usage. Estimating ${AvailableDiskGB}GB." -Tags "WARN" }
        } elseif ($null -eq $AvailableDiskGB -or $AvailableDiskGB -le 0) {
            $AvailableDiskGB = 50
            if ($IncludeDiskCheck) { Write-Information -MessageData "  [WARN] Could not read any disk info. Assuming ${AvailableDiskGB}GB." -Tags "WARN" }
        }
        Write-Information -MessageData "  Docker free disk: ${AvailableDiskGB}GB" -Tags "INFO"
        Write-Information -MessageData "  Fleet reserved: ${FleetReservedGB}GB | Available: ${AvailableGB}GB" -Tags "INFO"

        Set-Item -Path "Env:\DOCKER_TOTAL_MEMORY_GB" -Value $DockerTotalGB
        Set-Item -Path "Env:\DOCKER_DISK_AVAILABLE_GB" -Value $AvailableDiskGB

        Write-SetupLog "Phase 0c: Total=${DockerTotalGB}GB Available=${AvailableGB}GB Disk=${AvailableDiskGB}GB"

        $result = [pscustomobject]@{
            TotalGB            = $DockerTotalGB
            AvailableGB        = $AvailableGB
            AvailableDiskGB    = $AvailableDiskGB
        }
        $script:DockerResourcesCache = $result
        return $result
    }
    catch {
        Write-Information -MessageData "  [WARN] Measure-DockerResources encountered an error. Using fallback defaults." -Tags "WARN"
        Write-SetupLog "WARN: Measure-DockerResources failed: $($_.Exception.Message). Using fallback defaults." -Level WARN
        $DockerTotalGB = 16
        $AvailableGB = 16 - ($AgentCount * 4)
        if ($AvailableGB -lt 1) { $AvailableGB = 1 }
        $AvailableDiskGB = 50

        Set-Item -Path "Env:\DOCKER_TOTAL_MEMORY_GB" -Value $DockerTotalGB
        Set-Item -Path "Env:\DOCKER_DISK_AVAILABLE_GB" -Value 50

        $fallbackResult = [pscustomobject]@{
            TotalGB            = $DockerTotalGB
            AvailableGB        = $AvailableGB
            AvailableDiskGB    = 50
        }
        $script:DockerResourcesCache = $fallbackResult
        return $fallbackResult
    }
}

