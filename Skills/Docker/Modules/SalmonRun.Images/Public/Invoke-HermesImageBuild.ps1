function Invoke-HermesImageBuild {
    [OutputType([void])]
    param([Parameter(Mandatory)] [string]$TargetDir)
    $InformationPreference = "Continue"
    Write-Information -MessageData "`n[HermesImageBuild] Checking official Hermes image..." -Tags "WARN"

    # Phase 1 v2: Hermes is the official Nous Research image. We pull it rather
    # than building the custom Python MVP from a local Dockerfile. A thin fleet
    # overlay can still be built from Infrastructure/hermes.Dockerfile if needed.
    $OfficialImage = "nousresearch/hermes-agent:latest"
    $DfPath = Join-Path $TargetDir "Infrastructure" "hermes.Dockerfile"

    $InspectResult = Invoke-NativeCommand { docker image inspect $OfficialImage --format '{{.Id}}' 2>$null }
    if (-not $InspectResult.Success) {
        Write-Information -MessageData "  [PULL] $OfficialImage not found locally. Pulling..." -Tags "WARN"
        $PullResult = Invoke-NativeCommand { docker pull $OfficialImage 2>&1 }
        if (-not $PullResult.Success) {
            throw "Failed to pull $OfficialImage : $($PullResult.Output)"
        }
        Write-Information -MessageData "  [OK] $OfficialImage pulled successfully." -Tags "INFO"
    } else {
        Write-Information -MessageData "  [OK] $OfficialImage found locally." -Tags "INFO"
    }

    # Optional thin overlay build (e.g. labels, config seed). If the Dockerfile
    # is only a bare FROM statement, this is a no-op cache build.
    if (Test-Path $DfPath) {
        try {
            Push-Location $TargetDir
            $SourceHash = Get-ImageSourceHash -DockerfilePath $DfPath -TargetDir $TargetDir -ImageName "hermes"
            $ExistingIdResult = Invoke-NativeCommand { docker image inspect hermes:local --format '{{.Id}}' 2>$null }
            $ExistingHash = $null
            if ($ExistingIdResult.Success) {
                $ExistingHash = (Invoke-NativeCommand { docker image inspect hermes:local --format '{{index .Config.Labels "org.interclaw.hermes.source-hash"}}' 2>$null }).Output
            }
            if (-not $ExistingIdResult.Success -or -not $ExistingHash -or $ExistingHash -ne $SourceHash) {
                Write-Information -MessageData "  [BUILD] Building hermes:local overlay from $DfPath ..." -Tags "WARN"
                $savedPreference = $PSNativeCommandUseErrorActionPreference
                $PSNativeCommandUseErrorActionPreference = $false
                $buildOutput = docker build --progress=plain -f $DfPath `
                    -t "hermes:local" `
                    --label "org.interclaw.hermes.source-hash=$SourceHash" `
                    . 2>&1
                $PSNativeCommandUseErrorActionPreference = $savedPreference
                $buildOutput | Write-Information -Tags "INFO"
                if ($LASTEXITCODE -ne 0) {
                    throw "Docker build exited with code $LASTEXITCODE"
                }
                Write-Information -MessageData "  [OK] hermes:local overlay built successfully." -Tags "INFO"
            } else {
                Write-Information -MessageData "  [OK] hermes:local overlay is up to date." -Tags "INFO"
            }
        } catch {
            throw
        } finally {
            Pop-Location -ErrorAction SilentlyContinue
        }
    }
}
