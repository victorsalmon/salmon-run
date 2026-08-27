<#
.SYNOPSIS
    Builds or skips the funnel-proxy Docker image with source-hash caching.
.DESCRIPTION
    Checks whether funnel-proxy:local exists and whether its source hash label
    matches the current source. Rebuilds only when stale or missing. Uses
    $TargetDir, $SourceHash, and helper functions from the calling scope.
    Intended for invocation within the 0setup.ps1 / 1Deploy.ps1 pipeline.
.OUTPUTS
    None. Throws on build failure.
#>
function Invoke-FunnelProxyImageBuild {
    [OutputType([void])]
    param([Parameter(Mandatory)] [string]$TargetDir)
    Write-Information -MessageData "`n[FunnelProxyImageBuild] Checking funnel-proxy image..." -Tags "WARN"

    $DfPath = Join-Path $TargetDir "Infrastructure" "funnel-proxy.Dockerfile"
    $ExistingIdResult = Invoke-NativeCommand { docker image inspect funnel-proxy:local --format '{{.Id}}' 2>$null }
    $ExistingId = if ($ExistingIdResult.Success) { $ExistingIdResult.Output } else { $null }

    $SourceHash = Get-ImageSourceHash -DockerfilePath $DfPath -TargetDir $TargetDir -ImageName "funnel-proxy"

    $ExistingHash = $null
    if ($ExistingId) {
        $ExistingHashResult = Invoke-NativeCommand { docker image inspect funnel-proxy:local --format '{{index .Config.Labels "org.interclaw.funnel-proxy.source-hash"}}' 2>$null }
    $ExistingHash = if ($ExistingHashResult.Success) { $ExistingHashResult.Output } else { $null }
    }

    $Rebuild = $false
    if ($ExistingId) {
        if ($ExistingHash -and $SourceHash -and $ExistingHash -eq $SourceHash) {
            Write-Information -MessageData "  [OK] funnel-proxy:local image found (source hash matched)." -Tags "INFO"
            Write-Information -MessageData "  [SKIP] Using existing funnel-proxy:local image." -Tags "INFO"
        }
        else {
            $Reason = if (-not $ExistingHash) { "no source-hash label" } else { "source files changed" }
            Write-Information -MessageData "  [STALE] funnel-proxy:local image is stale ($Reason)." -Tags "WARN"
            Write-SetupLog "Funnel-proxy image stale: $Reason (old=$ExistingHash new=$SourceHash)"
            $Rebuild = $true
        }
    }
    else {
        Write-Information -MessageData "  [BUILD] funnel-proxy:local image not found. Building..." -Tags "WARN"
        $Rebuild = $true
    }

    if ($Rebuild) {
        if (-not (Test-Path $DfPath)) {
            Write-SetupLog "FAIL: funnel-proxy Dockerfile not found" -Level ERROR
            Write-Information -MessageData "  [FAIL] No funnel-proxy Dockerfile found at $DfPath." -Tags "ERROR"
            throw "No funnel-proxy Dockerfile found at $DfPath."
        }

        try {
            Push-Location $TargetDir
            $null = Invoke-DockerWithLogging -Command { docker image rm funnel-proxy:latest 2>&1 } -OperationLabel "Removing old funnel-proxy:latest"
            $savedPreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
            $buildOutput = docker build --progress=plain -f $DfPath `
                -t "funnel-proxy:local" `
                --label "org.interclaw.funnel-proxy.source-hash=$SourceHash" `
                . 2>&1
            $PSNativeCommandUseErrorActionPreference = $savedPreference
            $buildOutput | Write-Information -Tags "INFO"
            if ($LASTEXITCODE -ne 0) {
                throw "Docker build exited with code $LASTEXITCODE"
            }
            Write-Information -MessageData "  [OK] funnel-proxy:local built successfully." -Tags "INFO"
            Write-SetupLog "funnel-proxy:local image built"
        }
        catch {
            Write-SetupLog "FAIL: funnel-proxy Docker build failed: $($_.Exception.Message)" -Level ERROR
            Write-Information -MessageData "  [FAIL] funnel-proxy Docker build failed: see log for details" -Tags "ERROR"
            throw
        }
        finally {
            Pop-Location -ErrorAction SilentlyContinue
        }
    }
}

