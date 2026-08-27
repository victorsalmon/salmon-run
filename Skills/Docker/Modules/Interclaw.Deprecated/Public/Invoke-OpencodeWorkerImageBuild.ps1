<#
.SYNOPSIS
    [DEPRECATED] Builds the opencode-worker Docker image (replaced by code-worker).
.DESCRIPTION
    Legacy image build function kept for reference. Use Invoke-CodeWorkerImageBuild instead.
.PARAMETER
    This function takes no parameters.
.OUTPUTS
    None.
#>
Write-Warning "Invoke-OpencodeWorkerImageBuild is deprecated. Use Invoke-CodeWorkerImageBuild instead."

function Invoke-OpencodeWorkerImageBuild {
    [OutputType([void])]
    param()
    Write-Information -MessageData "`n[OpencodeWorkerImageBuild] Checking opencode-worker image..." -Tags "WARN"

    $WorkerDockerfilePath = Join-Path $TargetDir "Infrastructure" "opencode-worker.Dockerfile"
    $WorkerExistingId = docker image inspect opencode-worker:local --format '{{.Id}}' 2>$null

    $WorkerSourceHash = $null
    $HashInput = Get-Content $WorkerDockerfilePath -Raw -ErrorAction SilentlyContinue
    $CopyMatches = [regex]::Matches($HashInput, 'COPY\s+(\S+)\s+', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($Cm in $CopyMatches) {
        $CopySrc = Join-Path $TargetDir ($Cm.Groups[1].Value -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar)
        if (Test-Path $CopySrc -PathType Leaf) {
            $HashInput += "`n---$($Cm.Groups[1].Value)---`n" + (Get-Content $CopySrc -Raw)
        }
        elseif (Test-Path $CopySrc -PathType Container) {
            $AllFiles = Get-ChildItem -Path $CopySrc -File -Recurse | Sort-Object FullName
            foreach ($File in $AllFiles) {
                $RelativePath = $File.FullName.Substring($CopySrc.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
                $HashInput += "`n---$($Cm.Groups[1].Value)$RelativePath---`n" + (Get-Content $File.FullName -Raw)
            }
        }
    }
    $WorkerSourceHash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($HashInput))) -Algorithm SHA256).Hash.Substring(0, 16)

    $WorkerExistingHash = $null
    if ($WorkerExistingId) {
        $WorkerExistingHash = docker image inspect opencode-worker:local --format '{{index .Config.Labels "org.interclaw.worker.source-hash"}}' 2>$null
    }

    $RebuildWorker = $false
    if ($WorkerExistingId) {
        if ($WorkerExistingHash -and $WorkerSourceHash -and $WorkerExistingHash -eq $WorkerSourceHash) {
            Write-Information -MessageData "  [OK] opencode-worker:local image found (source hash matched)." -Tags "INFO"
            Write-Information -MessageData "  [SKIP] Using existing opencode-worker:local image." -Tags "INFO"
        }
        else {
            $Reason = if (-not $WorkerExistingHash) { "no source-hash label" } else { "source files changed" }
            Write-Information -MessageData "  [STALE] opencode-worker:local image is stale ($Reason)." -Tags "WARN"
            Write-SetupLog "Opencode worker image stale: $Reason (old=$WorkerExistingHash new=$WorkerSourceHash)"
            $RebuildWorker = $true
        }
    }
    else {
        Write-Information -MessageData "  [BUILD] opencode-worker:local image not found. Building..." -Tags "WARN"
        $RebuildWorker = $true
    }

    if ($RebuildWorker) {
        if (-not (Test-Path $WorkerDockerfilePath)) {
            Write-SetupLog "FAIL: Opencode worker Dockerfile not found" -Level ERROR
            Write-Information -MessageData "  [FAIL] No opencode-worker Dockerfile found at $WorkerDockerfilePath." -Tags "ERROR"
            exit 1
        }

        try {
            Push-Location $TargetDir
            docker image rm opencode-worker:latest 2>$null | Out-Null
            docker build -f $WorkerDockerfilePath `
                -t "opencode-worker:local" `
                --label "org.interclaw.worker.source-hash=$WorkerSourceHash" `
                . 2>&1 | Write-Information -Tags "INFO"
            if ($LASTEXITCODE -ne 0) {
                throw "Docker build exited with code $LASTEXITCODE"
            }
            Write-Information -MessageData "  [OK] opencode-worker:local built successfully." -Tags "INFO"
            Write-SetupLog "opencode-worker:local image built"
        }
        catch {
            Write-SetupLog "FAIL: opencode-worker Docker build failed: $($_.Exception.Message)" -Level ERROR
            Write-Information -MessageData "  [FAIL] opencode-worker Docker build failed: $($_.Exception.Message)" -Tags "ERROR"
            throw
        }
        finally {
            Pop-Location -ErrorAction SilentlyContinue
        }
    }
}

