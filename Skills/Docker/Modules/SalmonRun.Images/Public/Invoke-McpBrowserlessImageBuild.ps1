<#
.SYNOPSIS
    Build or skip the mcp_browserless:local Docker image based on source-hash comparison.
.DESCRIPTION
    Checks whether a mcp_browserless:local image exists and whether its source-hash
    label matches the current Dockerfile. Rebuilds only when stale or missing.
.PARAMETER TargetDir
    Root directory containing the Infrastructure/mcp_browserless.Dockerfile.
#>
function Invoke-McpBrowserlessImageBuild {
    [OutputType([void])]
    param([Parameter(Mandatory)] [string]$TargetDir)
    Write-Information -MessageData "`n[Invoke-McpBrowserlessImageBuild] Checking mcp_browserless image..." -Tags "WARN"

    $DfPath = Join-Path $TargetDir "Infrastructure" "mcp_browserless.Dockerfile"
    $ExistingIdResult = Invoke-NativeCommand { docker image inspect mcp_browserless:local --format '{{.Id}}' 2>$null }
    $ExistingId = if ($ExistingIdResult.Success) { $ExistingIdResult.Output } else { $null }

    $SourceHash = Get-ImageSourceHash -DockerfilePath $DfPath -TargetDir $TargetDir -ImageName "mcp_browserless"

    $ExistingHash = $null
    if ($ExistingId) {
        $ExistingHashResult = Invoke-NativeCommand { docker image inspect mcp_browserless:local --format '{{index .Config.Labels "org.interclaw.mcp_browserless.source-hash"}}' 2>$null }
    $ExistingHash = if ($ExistingHashResult.Success) { $ExistingHashResult.Output } else { $null }
    }

    $Rebuild = $false
    if ($ExistingId) {
        if ($ExistingHash -and $SourceHash -and $ExistingHash -eq $SourceHash) {
            Write-Information -MessageData "  [OK] mcp_browserless:local image found (source hash matched)." -Tags "INFO"
            Write-Information -MessageData "  [SKIP] Using existing mcp_browserless:local image." -Tags "INFO"
        }
        else {
            $Reason = if (-not $ExistingHash) { "no source-hash label" } else { "source files changed" }
            Write-Information -MessageData "  [STALE] mcp_browserless:local image is stale ($Reason)." -Tags "WARN"
            Write-SetupLog "MCP browserless image stale: $Reason (old=$ExistingHash new=$SourceHash)"
            $Rebuild = $true
        }
    }
    else {
        Write-Information -MessageData "  [BUILD] mcp_browserless:local image not found. Building..." -Tags "WARN"
        $Rebuild = $true
    }

    if ($Rebuild) {
        if (-not (Test-Path $DfPath)) {
            Write-SetupLog "FAIL: mcp_browserless Dockerfile not found" -Level ERROR
            Write-Information -MessageData "  [FAIL] No mcp_browserless Dockerfile found at $DfPath." -Tags "ERROR"
            throw "No mcp_browserless Dockerfile found at $DfPath."
        }

        try {
            Push-Location $TargetDir
            $null = Invoke-DockerWithLogging -Command { docker image rm mcp_browserless:latest 2>&1 } -OperationLabel "Removing old mcp_browserless:latest"
            $savedPreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
            $buildOutput = docker build --progress=plain -f $DfPath `
                -t "mcp_browserless:local" `
                --label "org.interclaw.mcp_browserless.source-hash=$SourceHash" `
                . 2>&1
            $PSNativeCommandUseErrorActionPreference = $savedPreference
            $buildOutput | Write-Information -Tags "INFO"
            if ($LASTEXITCODE -ne 0) {
                throw "Docker build exited with code $LASTEXITCODE"
            }
            Write-Information -MessageData "  [OK] mcp_browserless:local built successfully." -Tags "INFO"
            Write-SetupLog "mcp_browserless:local image built"
        }
        catch {
            Write-SetupLog "FAIL: mcp_browserless Docker build failed: $($_.Exception.Message)" -Level ERROR
            Write-Information -MessageData "  [FAIL] mcp_browserless Docker build failed: see log for details" -Tags "ERROR"
            throw
        }
        finally {
            Pop-Location -ErrorAction SilentlyContinue
        }
    }
}

