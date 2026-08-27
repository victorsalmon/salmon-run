<#
.SYNOPSIS
    Build or skip the docusign:local Docker image based on source-hash comparison.
.DESCRIPTION
    Checks whether a docusign:local image exists and whether its source-hash
    label matches the current Dockerfile. Rebuilds only when stale or missing.
    Supports building the DocuSign server from a source repo other than the
    orchestrator (e.g. intersite-docs/Docusign/server) by staging the shared
    fleet-auth.cjs middleware into the build context.
.PARAMETER TargetDir
    Root directory of the orchestrator repo containing install.json.
#>
function Invoke-DocusignImageBuild {
    [OutputType([void])]
    param([string]$TargetDir = $script:TargetDir)
    if (-not $TargetDir) { throw "TargetDir is required" }
    Write-Information -MessageData "`n[DocusignImageBuild] Checking docusign image..." -Tags "WARN"
    Write-SetupLog "BUILD: Building docusign:local image..."

    $installJsonPath = Join-Path $TargetDir "install.json"
    $docusignRepo = "intersite-docs"
    $docusignSourceDir = "Docusign/server"
    if (Test-Path -LiteralPath $installJsonPath) {
        $install = Get-Content $installJsonPath -Raw | ConvertFrom-Json
        if ($install.features.docusign.repo) { $docusignRepo = $install.features.docusign.repo }
        if ($install.features.docusign.sourceDir) { $docusignSourceDir = $install.features.docusign.sourceDir }
    }

    $repoRoot = if (-not $docusignRepo) { $TargetDir } elseif ([System.IO.Path]::IsPathRooted($docusignRepo)) { $docusignRepo } else { Join-Path ([Environment]::GetEnvironmentVariable("USERPROFILE")) $docusignRepo }
    $ServerDir = Join-Path $repoRoot $docusignSourceDir
    $DfPath = Join-Path $ServerDir "docusign.Dockerfile"

    if (-not (Test-Path -LiteralPath $ServerDir)) {
        Write-SetupLog "FAIL: DocuSign server source directory not found: $ServerDir" -Level ERROR
        throw "DocuSign server source directory not found: $ServerDir"
    }

    # Stage shared fleet auth middleware into the build context.
    $authDestDir = Join-Path $ServerDir "auth"
    $authDest = Join-Path $authDestDir "fleet-auth.cjs"
    $authSource = Join-Path $TargetDir "Infrastructure/auth/fleet-auth.cjs"
    if (Test-Path -LiteralPath $authSource) {
        $null = New-Item -ItemType Directory -Path $authDestDir -Force
        $needsCopy = $true
        if (Test-Path -LiteralPath $authDest) {
            $srcHash = (Get-FileHash -LiteralPath $authSource -Algorithm SHA256).Hash
            $dstHash = (Get-FileHash -LiteralPath $authDest -Algorithm SHA256).Hash
            if ($srcHash -eq $dstHash) { $needsCopy = $false }
        }
        if ($needsCopy) {
            Copy-Item -LiteralPath $authSource -Destination $authDest -Force
            Write-SetupLog "Staging fleet-auth.cjs into DocuSign build context"
        }
    }
    else {
        Write-SetupLog "WARN: fleet-auth.cjs not found; build may fail if Dockerfile expects it" -Level WARN
    }

    $ExistingIdResult = Invoke-NativeCommand { docker image inspect docusign:local --format '{{.Id}}' 2>$null }
    $ExistingId = if ($ExistingIdResult.Success) { $ExistingIdResult.Output } else { $null }

    $SourceHash = Get-ImageSourceHash -DockerfilePath $DfPath -TargetDir $ServerDir -ImageName "docusign"

    $ExistingHash = $null
    if ($ExistingId) {
        $ExistingHashResult = Invoke-NativeCommand { docker image inspect docusign:local --format '{{index .Config.Labels "org.interclaw.docusign.source-hash"}}' 2>$null }
        $ExistingHash = if ($ExistingHashResult.Success) { $ExistingHashResult.Output } else { $null }
    }

    $Rebuild = $false
    if ($ExistingId) {
        if ($ExistingHash -and $SourceHash -and $ExistingHash -eq $SourceHash) {
            Write-Information -MessageData "  [OK] docusign:local image found (source hash matched)." -Tags "INFO"
            Write-Information -MessageData "  [SKIP] Using existing docusign:local image." -Tags "INFO"
        }
        else {
            $Reason = if (-not $ExistingHash) { "no source-hash label" } else { "source files changed" }
            Write-Information -MessageData "  [STALE] docusign:local image is stale ($Reason)." -Tags "WARN"
            Write-SetupLog "Docusign image stale: $Reason (old=$ExistingHash new=$SourceHash)"
            $Rebuild = $true
        }
    }
    else {
        Write-Information -MessageData "  [BUILD] docusign:local image not found. Building..." -Tags "WARN"
        Write-SetupLog "docusign:local image built"
        $Rebuild = $true
    }

    if ($Rebuild) {
        if (-not (Test-Path $DfPath)) {
            Write-SetupLog "FAIL: docusign Dockerfile not found" -Level ERROR
            Write-Information -MessageData "  [FAIL] No docusign Dockerfile found at $DfPath." -Tags "ERROR"
            throw "No docusign Dockerfile found at $DfPath."
        }

        try {
            $savedPreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
            $buildOutput = docker build --progress=plain -f $DfPath `
                -t "docusign:local" `
                --label "org.interclaw.docusign.source-hash=$SourceHash" `
                $ServerDir 2>&1
            $PSNativeCommandUseErrorActionPreference = $savedPreference
            $buildOutput | Write-Information -Tags "INFO"
            if ($LASTEXITCODE -ne 0) {
                throw "Docker build exited with code $LASTEXITCODE"
            }
            Write-Information -MessageData "  [OK] docusign:local built successfully." -Tags "INFO"
            Write-SetupLog "docusign:local image built"
        }
        catch {
            Write-SetupLog "FAIL: docusign Docker build failed: $($_.Exception.Message)" -Level ERROR
            Write-Information -MessageData "  [FAIL] docusign Docker build failed: see log for details" -Tags "ERROR"
            throw
        }
    }
}
