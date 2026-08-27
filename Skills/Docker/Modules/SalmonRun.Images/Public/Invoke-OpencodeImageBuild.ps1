<#
.SYNOPSIS
    Builds the opencode Docker image if stale or missing.
.DESCRIPTION
    Checks existing opencode:local image against source file hashes
    (Dockerfile, sh, opencode.json). Rebuilds if stale.
.PARAMETER
    This function takes no parameters. Uses $TargetDir from caller scope.
.OUTPUTS
    None.
#>
function Invoke-OpencodeImageBuild {
    [OutputType([void])]
    param([Parameter(Mandatory)] [string]$TargetDir)
    Write-Information -MessageData "`n[OpencodeImageBuild] Checking opencode image..." -Tags "WARN"

    $DockerfilePath = Join-Path $TargetDir "Infrastructure" "opencode" "Dockerfile"
    $ExistingIdResult = Invoke-NativeCommand { docker image inspect opencode:local --format '{{.Id}}' 2>$null }
    $ExistingId = if ($ExistingIdResult.Success) { $ExistingIdResult.Output } else { $null }

    $SourceHash = Get-ImageSourceHash -DockerfilePath $DockerfilePath -TargetDir $TargetDir -ImageName "opencode"

    $ExistingHash = $null
    if ($ExistingId) {
        $ExistingHashResult = Invoke-NativeCommand { docker image inspect opencode:local --format '{{index .Config.Labels "org.interclaw.source-hash"}}' 2>$null }
    $ExistingHash = if ($ExistingHashResult.Success) { $ExistingHashResult.Output } else { $null }
    }

    $Rebuild = $false
    if ($ExistingId) {
        if ($ExistingHash -and $SourceHash -and $ExistingHash -eq $SourceHash) {
            Write-Information -MessageData "  [OK] opencode:local image found (source hash matched)." -Tags "INFO"
            Write-Information -MessageData "  [SKIP] Using existing opencode:local image." -Tags "INFO"
        }
        else {
            $Reason = if (-not $ExistingHash) { "no source-hash label" } else { "source files changed" }
            Write-Information -MessageData "  [STALE] opencode:local image is stale ($Reason)." -Tags "WARN"
            Write-SetupLog "Opencode image stale: $Reason (old=$ExistingHash new=$SourceHash)"
            $Rebuild = $true
        }
    }
    else {
        Write-Information -MessageData "  [BUILD] opencode:local image not found. Building..." -Tags "WARN"
        $Rebuild = $true
    }

    if ($Rebuild) {
        if (-not (Test-Path $DockerfilePath)) {
            Write-SetupLog "FAIL: Opencode Dockerfile not found" -Level ERROR
            Write-Information -MessageData "  [FAIL] No opencode Dockerfile found at $DockerfilePath." -Tags "ERROR"
            throw "No opencode Dockerfile found at $DockerfilePath."
        }

        try {
            Push-Location $TargetDir
            $null = Invoke-DockerWithLogging -Command { docker image rm opencode:latest 2>&1 } -OperationLabel "Removing old opencode:latest"
            $savedPreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
            $buildOutput = docker build --progress=plain -f $DockerfilePath `
                -t "opencode:local" `
                --label "org.interclaw.source-hash=$SourceHash" `
                . 2>&1
            $PSNativeCommandUseErrorActionPreference = $savedPreference
            $buildOutput | Write-Information -Tags "INFO"
            if ($LASTEXITCODE -ne 0) {
                throw "Docker build exited with code $LASTEXITCODE"
            }
            Write-Information -MessageData "  [OK] opencode:local built successfully." -Tags "INFO"
            Write-SetupLog "opencode:local image built"
        }
        catch {
            Write-SetupLog "FAIL: opencode Docker build failed: $($_.Exception.Message)" -Level ERROR
            Write-Information -MessageData "  [FAIL] opencode Docker build failed: see log for details" -Tags "ERROR"
            throw
        }
        finally {
            Pop-Location -ErrorAction SilentlyContinue
        }
    }
}


