<#
.SYNOPSIS
    Launches parallel Docker image builds as background jobs.
.DESCRIPTION
    Starts 4 concurrent background jobs for: ORCHESTRATOR image pull, fleet build,
    code-worker build, and api-proxy build. Returns immediately with job handles
    and build log directory path.
.PARAMETER TargetDir
    Repository root directory (used by build functions).
.PARAMETER ImageVersion
    Version tag for images (default: "local").
.OUTPUTS
    [hashtable] with Keys: Jobs (array of Job), BuildLogDir (string).
#>
function Start-ParallelImageBuild {
    [OutputType([hashtable])]
    param(
        [string]$TargetDir,
        [string]$ImageVersion = "local",
        [switch]$ForceRebuild
    )
    $buildLogDir = Join-Path (Get-ReportsDir) "build-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-Item -ItemType Directory -Path $buildLogDir -Force | Out-Null

    $imagesPublicDir = Join-Path $TargetDir "Skills" "Docker" "Modules" "SalmonRun.Images" "Public"
    $deployPublicDir = Join-Path $TargetDir "Skills" "Docker" "Modules" "SalmonRun.Deploy" "Public"
    $salmonModulesDir = Join-Path $TargetDir "Skills" "Orchestrator" "Salmon" "Modules"
    $coreModulePath = Join-Path $salmonModulesDir "SalmonRun.Core" "SalmonRun.Core.ps1"

    $jobDefs = @(
        @{ Name = "ORCHESTRATOR-pull";   FuncName = "Invoke-ImagePull";             Label = "ORCHESTRATOR:latest" }
        @{ Name = "is-fleet";       FuncName = "Invoke-FleetImageBuild";       Label = "is-fleet:local" }
        @{ Name = "opencode";        FuncName = "Invoke-OpencodeImageBuild";      Label = "opencode:local" }
        @{ Name = "mcp_browserless";  FuncName = "Invoke-McpBrowserlessImageBuild";     Label = "mcp_browserless:local" }
        @{ Name = "ops-funnel-proxy"; FuncName = "Invoke-FunnelProxyImageBuild";         Label = "ops-funnel-proxy:local" }
        @{ Name = "is-marketer";     FuncName = "Invoke-MarketerImageBuild";             Label = "marketer:local" }
        @{ Name = "is-hermes";      FuncName = "Invoke-HermesImageBuild";               Label = "hermes:local" }
    )

    if ($ForceRebuild) { $env:ORCHESTRATOR_FORCE_REBUILD = "true" }

    $jobs = [System.Collections.ArrayList]::new()
    foreach ($jd in $jobDefs) {
        $jobName = $jd.Name
        $funcName = $jd.FuncName
        $label = $jd.Label
        $funcDir = if ($funcName -eq "Invoke-ImagePull") { $deployPublicDir } else { $imagesPublicDir }
        $job = Start-Job -Name $jobName -ScriptBlock {
            param($T, $ID, $DD, $C, $LogDir, $IV, $FuncName, $Label, $SalmonModules)
            $ErrorActionPreference = "Stop"
            $__modulesDir = "$([System.IO.Path]::GetFullPath("$T/Skills/Docker/Modules"))"
            if ($__modulesDir -and (Test-Path $__modulesDir)) {
                $env:PSModulePath = "$__modulesDir;$env:PSModulePath"
            }
            if ($SalmonModules -and (Test-Path $SalmonModules)) {
                $env:PSModulePath = "$SalmonModules;$env:PSModulePath"
            }
            . $C
            . (Join-Path $ID "$FuncName.ps1")
            . (Join-Path $DD "Get-ImageSourceHash.ps1")
            $script:TargetDir = $T
            $script:ImageVersion = $IV
            $start = Get-Date
            $tmpFile = $null
            try {
                $buildOutput = & $FuncName *>&1; $logFile = Join-Path $LogDir "$FuncName.log"; $tmpFile = "$logFile.$([Guid]::NewGuid().ToString('N')).tmp"; $buildOutput | Out-File -FilePath $tmpFile -Encoding UTF8; if (Test-Path $logFile) { $existing = Get-Content $logFile -Raw -ErrorAction SilentlyContinue; if ($existing) { "$($existing.TrimEnd())`r`n$(Get-Content $tmpFile -Raw)" | Out-File -FilePath $tmpFile -Encoding UTF8 } }; Move-Item -LiteralPath $tmpFile -Destination $logFile -Force; $tmpFile = $null
                $durationMs = [math]::Round(((Get-Date) - $start).TotalMilliseconds)
                return @{ Name = $Label; Success = $true; DurationMs = $durationMs }
            } catch {
                $durationMs = [math]::Round(((Get-Date) - $start).TotalMilliseconds)
                $errMsg = if ($_.Exception.Message) { $_.Exception.Message } else { $_.ToString() }
                return @{ Name = $Label; Success = $false; DurationMs = $durationMs; Error = $errMsg }
            } finally {
                if ($tmpFile -and (Test-Path $tmpFile)) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
            }
        } -ArgumentList $TargetDir, $funcDir, $deployPublicDir, $coreModulePath, $buildLogDir, $ImageVersion, $funcName, $label, $salmonModulesDir

        if ($job) {
            [void]$jobs.Add($job)
            $jobId = $job.Id
            Write-Information -MessageData "[BUILD] Started $label (job $jobId)" -Tags "INFO"
            Write-SetupLog "Parallel build started: $label (job $jobId)"
        } else {
            Write-SetupLog "FAIL: Failed to start job for $label" -Level ERROR
            Write-Information -MessageData "[BUILD] FAILED to start $label" -Tags "ERROR"
        }
    }

    return @{ Jobs = $jobs.ToArray(); BuildLogDir = $buildLogDir }
}

