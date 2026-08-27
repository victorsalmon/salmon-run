<#
.SYNOPSIS
    Pre-pulls base Docker images to avoid network contention during parallel builds.
.DESCRIPTION
    Scans Dockerfiles under Infrastructure/ for FROM directives, collects unique
    base images, and pulls each one sequentially. Reports pull results via
    Write-SetupLog and Write-Information.
.PARAMETER TargetDir
    The root directory containing the Infrastructure/ folder with Dockerfiles.
#>
function Invoke-PrePullBaseImages {
    [OutputType([void])]
    param(
        [string]$TargetDir
    )

    Write-Information -MessageData "`n[PrePullBaseImages] Pre-pulling base images to avoid network contention during parallel builds..." -Tags "INFO"

    $baseImages = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $dockerfiles = @(
        Join-Path $TargetDir "Infrastructure" "opencode" "Dockerfile"
    )
    Get-ChildItem (Join-Path $TargetDir "Infrastructure") -Filter "*.Dockerfile" | ForEach-Object {
        $dockerfiles += $_.FullName
    }

    foreach ($df in $dockerfiles) {
        if (-not (Test-Path $df)) { continue }
        $content = Get-Content $df -Raw
        $fromLines = [regex]::Matches($content, '(?m)^FROM\s+(\S+)')
        foreach ($match in $fromLines) {
            $image = $match.Groups[1].Value
            $separator = $image.IndexOf('@')
            if ($separator -gt 0) {
                $image = $image.Substring(0, $separator)
            }
            [void]$baseImages.Add($image)
        }
    }

    if ($baseImages.Count -eq 0) {
        Write-Information -MessageData "  [SKIP] No base images found to pre-pull." -Tags "INFO"
        return
    }

    Write-Information -MessageData "  Found $($baseImages.Count) unique base image(s):" -Tags "INFO"
    foreach ($img in $baseImages) {
        Write-Information -MessageData "    - $img" -Tags "INFO"
    }

    function Get-PinnedDigest {
        param([string]$DockerfilePath, [string]$ImageName)
        $content = Get-Content $DockerfilePath -Raw
        $pattern = '(?m)^FROM\s+' + [regex]::Escape($ImageName) + '.*?@sha256:(\w{64})'
        $match = [regex]::Match($content, $pattern)
        if ($match.Success) { return $match.Groups[1].Value }
        return $null
    }

    function Get-PulledDigest {
        param([string]$ImageName)
        try {
            $result = docker image inspect $ImageName --format '{{.Id}}' 2>$null
            if ($result -match 'sha256:(\w{64})') { return $matches[1] }
        } catch {
                Write-SetupLog "Pre-pull: Get-PulledDigest failed for $ImageName : $_" -Level WARN
            }
        return $null
    }

    foreach ($img in $baseImages) {
        Write-Information -MessageData "  [PULL] docker pull $img ..." -Tags "WARN"
        try {
            $result = Invoke-NativeCommand { docker pull $img 2>&1 | Write-Information -Tags "INFO" }
            if ($result.Success) {
                Write-Information -MessageData "    [OK] $img pulled." -Tags "INFO"
                Write-SetupLog "Pre-pull OK: $img"

                $pulledDigest = Get-PulledDigest -ImageName $img
                if ($pulledDigest) {
                    foreach ($df in $dockerfiles) {
                        if (-not (Test-Path $df)) { continue }
                        $pinnedDigest = Get-PinnedDigest -DockerfilePath $df -ImageName $img
                        if ($pinnedDigest -and $pinnedDigest -ne $pulledDigest) {
                            $msg = "Digest mismatch for $img in $(Split-Path $df -Leaf): pinned=$pinnedDigest pulled=$pulledDigest — re-pin recommended"
                            Write-Information -MessageData "    [WARN] $msg" -Tags "WARN"
                            Write-SetupLog "Pre-pull DIGEST-MISMATCH: $msg" -Level WARN
                        }
                    }
                }
            } else {
                Write-Information -MessageData "    [WARN] $img pull had issues (non-fatal)." -Tags "WARN"
                Write-SetupLog "Pre-pull WARN: $img returned exit code $($result.ExitCode)" -Level WARN
            }
        } catch {
            Write-Information -MessageData "    [WARN] $img pull failed: $($_.Exception.Message)" -Tags "WARN"
            Write-SetupLog "Pre-pull WARN: $img failed: $($_.Exception.Message)" -Level WARN
        }
    }

    Write-Information -MessageData "  [OK] Base image pre-pull complete." -Tags "INFO"
}

