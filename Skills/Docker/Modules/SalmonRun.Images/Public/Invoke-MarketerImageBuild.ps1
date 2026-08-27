function Invoke-MarketerImageBuild {
    [OutputType([void])]
    param([Parameter(Mandatory)] [string]$TargetDir)
    $InformationPreference = "Continue"
    Write-Information -MessageData "`n[MarketerImageBuild] Checking marketer image..." -Tags "WARN"

    $DfPath = Join-Path $TargetDir "Infrastructure" "marketer.Dockerfile"
    $ExistingIdResult = Invoke-NativeCommand { docker image inspect marketer:local --format '{{.Id}}' 2>$null }
    $ExistingId = if ($ExistingIdResult.Success) { $ExistingIdResult.Output } else { $null }

    $SourceHash = Get-ImageSourceHash -DockerfilePath $DfPath -TargetDir $TargetDir -ImageName "marketer"

    $ExistingHash = $null
    if ($ExistingId) {
        $ExistingHashResult = Invoke-NativeCommand { docker image inspect marketer:local --format '{{index .Config.Labels "org.SalmonRun.Marketer.source-hash"}}' 2>$null }
        $ExistingHash = if ($ExistingHashResult.Success) { $ExistingHashResult.Output } else { $null }
    }

    $Rebuild = $false
    if ($ExistingId) {
        if ($ExistingHash -and $SourceHash -and $ExistingHash -eq $SourceHash) {
            Write-Information -MessageData "  [OK] marketer:local image found (source hash matched)." -Tags "INFO"
        } else {
            $Reason = if (-not $ExistingHash) { "no source-hash label" } else { "source files changed" }
            Write-Information -MessageData "  [STALE] marketer:local image is stale ($Reason)." -Tags "WARN"
            $Rebuild = $true
        }
    } else {
        Write-Information -MessageData "  [BUILD] marketer:local image not found. Building..." -Tags "WARN"
        $Rebuild = $true
    }

    if ($Rebuild) {
        if (-not (Test-Path $DfPath)) {
            throw "No marketer Dockerfile found at $DfPath."
        }
        try {
            Push-Location $TargetDir
            $null = Invoke-DockerWithLogging -Command { docker image rm marketer:latest 2>&1 } -OperationLabel "Removing old marketer:latest"
            $savedPreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
            $buildOutput = docker build --progress=plain -f $DfPath `
                -t "marketer:local" `
                --label "org.SalmonRun.Marketer.source-hash=$SourceHash" `
                . 2>&1
            $PSNativeCommandUseErrorActionPreference = $savedPreference
            $buildOutput | Write-Information -Tags "INFO"
            if ($LASTEXITCODE -ne 0) {
                throw "Docker build exited with code $LASTEXITCODE"
            }
            Write-Information -MessageData "  [OK] marketer:local built successfully." -Tags "INFO"
        } catch {
            throw
        } finally {
            Pop-Location -ErrorAction SilentlyContinue
        }
    }
}
