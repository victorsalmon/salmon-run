<#
.SYNOPSIS
    Builds the is-monitoring metrics exporter image.
#>
function Invoke-MonitoringImageBuild {
    [OutputType([void])]
    param([Parameter(Mandatory)] [string]$TargetDir)
    $InformationPreference = "Continue"
    Write-Information -MessageData "`n[MonitoringImageBuild] Checking monitoring image..." -Tags "WARN"

    $DfPath = Join-Path $TargetDir "Infrastructure" "monitoring" "Dockerfile"
    $ExistingIdResult = Invoke-NativeCommand { docker image inspect monitoring:local --format '{{.Id}}' 2>$null }
    $ExistingId = if ($ExistingIdResult.Success) { $ExistingIdResult.Output } else { $null }

    $SourceHash = Get-ImageSourceHash -DockerfilePath $DfPath -TargetDir $TargetDir -ImageName "monitoring"

    $ExistingHash = $null
    if ($ExistingId) {
        $ExistingHashResult = Invoke-NativeCommand { docker image inspect monitoring:local --format '{{index .Config.Labels "org.interclaw.monitoring.source-hash"}}' 2>$null }
        $ExistingHash = if ($ExistingHashResult.Success) { $ExistingHashResult.Output } else { $null }
    }

    $Rebuild = $false
    if ($ExistingId) {
        if ($ExistingHash -and $SourceHash -and $ExistingHash -eq $SourceHash) {
            Write-Information -MessageData "  [OK] monitoring:local image found (source hash matched)." -Tags "INFO"
            Write-Information -MessageData "  [SKIP] Using existing monitoring:local image." -Tags "INFO"
        }
        else {
            $Reason = if (-not $ExistingHash) { "no source-hash label" } else { "source files changed" }
            Write-Information -MessageData "  [STALE] monitoring:local image is stale ($Reason)." -Tags "WARN"
            Write-SetupLog "Monitoring image stale: $Reason (old=$ExistingHash new=$SourceHash)"
            $Rebuild = $true
        }
    }
    else {
        Write-Information -MessageData "  [BUILD] monitoring:local image not found. Building..." -Tags "WARN"
        $Rebuild = $true
    }

    if ($Rebuild) {
        if (-not (Test-Path $DfPath)) {
            Write-SetupLog "FAIL: monitoring Dockerfile not found" -Level ERROR
            Write-Information -MessageData "  [FAIL] No monitoring Dockerfile found at $DfPath." -Tags "ERROR"
            throw "No monitoring Dockerfile found at $DfPath."
        }

        try {
            Push-Location $TargetDir
            $null = Invoke-DockerWithLogging -Command { docker image rm monitoring:latest 2>&1 } -OperationLabel "Removing old monitoring:latest"
            $savedPreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
            $buildOutput = docker build --progress=plain -f $DfPath `
                -t "monitoring:local" `
                --label "org.interclaw.monitoring.source-hash=$SourceHash" `
                . 2>&1
            $PSNativeCommandUseErrorActionPreference = $savedPreference
            $buildOutput | Write-Information -Tags "INFO"
            if ($LASTEXITCODE -ne 0) {
                throw "Docker build exited with code $LASTEXITCODE"
            }
            Write-Information -MessageData "  [OK] monitoring:local built successfully." -Tags "INFO"
            Write-SetupLog "monitoring:local image built"
        }
        catch {
            Write-SetupLog "FAIL: monitoring Docker build failed: $($_.Exception.Message)" -Level ERROR
            Write-Information -MessageData "  [FAIL] monitoring Docker build failed: see log for details" -Tags "ERROR"
            throw
        }
        finally {
            Pop-Location -ErrorAction SilentlyContinue
        }
    }
}
