<#
.SYNOPSIS
    Creates and seeds Docker volumes for agent config, persistence, workspace repos, and shared memory.
.DESCRIPTION
    Iterates all configured agent roles, creates named config+persist volumes, seeds role-specific
    .md files (with {OWNER_*} placeholder substitution), validates sovereignty-tier agent JSON config,
    fixes volume ownership to uid 1000, and clones workspace repositories. Runs as part of deploy.
.PARAMETER WorkspaceRepos
    Semicolon-separated list of Git repository URLs to clone into the shared workspace volume.
.OUTPUTS
    None.
#>
function Initialize-AgentVolumes {
    [OutputType([void])]
param(
    [string]$WorkspaceRepos = "",
    [string]$StackName,
    [string]$SovereigntyTier,
    [hashtable[]]$AgentConfigs,
    [string]$TargetDir,
    [hashtable]$OwnerPlaceholders = @{}
)
    if (-not $script:StackName -and -not $StackName) {
        throw "Deploy state not initialized. Call Invoke-InterclawDeployment first."
    }
    if (-not $PSBoundParameters.ContainsKey('StackName')) {
        if ($script:StackName) { $StackName = $script:StackName }
        elseif ($script:ProjectCode) { $StackName = $script:ProjectCode }
    }
    if (-not $PSBoundParameters.ContainsKey('SovereigntyTier')) { $SovereigntyTier = $script:SovereigntyTier }
    if (-not $PSBoundParameters.ContainsKey('AgentConfigs')) { $AgentConfigs = $script:AgentConfigs }
    if (-not $PSBoundParameters.ContainsKey('TargetDir')) { $TargetDir = $script:TargetDir }
Write-SetupLog "Phase 2: Creating and seeding agent config volumes"
Write-Information -MessageData "`n[AgentVolumes] Initializing agent config volumes..." -Tags "WARN"

# Load owner placeholders for {OWNER_*} template substitution in .md files
if ($OwnerPlaceholders.Count -eq 0 -and (Get-Command Get-OwnerPlaceholders -ErrorAction SilentlyContinue)) {
    $OwnerPlaceholders = Get-OwnerPlaceholders
}

# --- Pre-flight: validate ALL agent config schemas first ---
Write-SetupLog "Pre-validating agent config schemas..." -Level INFO
$SchemaErrors = [System.Collections.Generic.List[pscustomobject]]::new()
$SovFolderMap = @{ "canada" = "Canada"; "usa" = "USA"; "global" = "Global" }
$SovUpper = $SovFolderMap[$SovereigntyTier]

foreach ($AgentCfg in $AgentConfigs) {
    $Role = $AgentCfg.Role
    $SovereigntyConfigSrc = Join-Path $TargetDir "Agents" $Role "$SovUpper" "ORCHESTRATOR.json"
    if (Test-Path -LiteralPath $SovereigntyConfigSrc) {
        try {
            $ConfigContent = Get-Content -LiteralPath $SovereigntyConfigSrc -Raw
            $Resolved = Resolve-StringPlaceholders -Text $ConfigContent -PlaceholderMap $OwnerPlaceholders
            $AgentConfigObj = $Resolved | ConvertFrom-Json
            $SchemaResult = Test-InterclawConfigSchema -Config $AgentConfigObj -ConfigType "Agent"
            if (-not $SchemaResult.Valid) {
                foreach ($Err in $SchemaResult.Errors) {
                    $SchemaErrors.Add([pscustomobject]@{
                        Agent  = "$($AgentCfg.Role)-$($AgentCfg.InstanceId)"
                        File   = $SovereigntyConfigSrc
                        Error  = $Err
                    })
                }
            }
        }
        catch {
            $SchemaErrors.Add([pscustomobject]@{
                Agent  = "$($AgentCfg.Role)-$($AgentCfg.InstanceId)"
                File   = $SovereigntyConfigSrc
                Error  = "Invalid JSON: $_"
            })
        }
    }
}

if ($SchemaErrors.Count -gt 0) {
    $ErrorReport = ($SchemaErrors | ForEach-Object { "  $($_.Agent): $($_.Error)" }) -join "`n"
    throw "Config schema validation failed for $($SchemaErrors.Count) agent(s):`n$ErrorReport`n`nFix config files before re-running deployment."
}
Write-SetupLog "All $($AgentConfigs.Count) agent config schemas valid" -Level INFO

# Capture variables for parallel runspaces (no scriptblocks '" not supported by $using:)
$LocalStackName = $StackName
$LocalTargetDir = $TargetDir
$LocalOwnerPlaceholders = $OwnerPlaceholders
$LocalSovUpper = $SovUpper
$LocalRoleFileMap = Get-RoleFileMap
$LocalSharedFiles = Get-SharedFiles
$LocalSetupLogPath = $env:INTERCLAW_SETUP_LOG

# Fix entrypoint.sh CRLF line endings once outside parallel block to avoid data race
$entrypointPath = Join-Path $TargetDir "Infrastructure" "entrypoint.sh"
if (Test-Path $entrypointPath) {
    $entryBytes = [System.IO.File]::ReadAllBytes($entrypointPath)
    $hasCRLF = $null -ne ($entryBytes | Where-Object { $_ -eq 0x0D } | Select-Object -First 1)
    if ($hasCRLF) {
        Write-SetupLog "WARN: entrypoint.sh has CRLF line endings - fixing before parallel volume seeding" -Level INFO
        $fixedContent = [System.IO.File]::ReadAllText($entrypointPath) -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText($entrypointPath, $fixedContent, [System.Text.UTF8Encoding]::new($false))
    }
}

$AgentConfigs | ForEach-Object -Parallel {
    $__savedPSDefault = $PSDefaultParameterValues
    try {
        $__logPath = $using:LocalSetupLogPath
    function Write-ParallelLog { param($m) if ($__logPath) { $mutex = $null; try { $mutex = New-Object System.Threading.Mutex($false, "Global\InterclawParallelLogMutex"); if (-not $mutex.WaitOne(5000)) { Write-Information -MessageData "Write-ParallelLog: mutex timeout for log file (5s) - log entry dropped: $m" -Tags "WARN"; return }; Add-Content -Path $__logPath -Value "[Parallel] $m" -Encoding UTF8 -ErrorAction Stop } catch { Write-Information -MessageData "Write-ParallelLog: failed to write: $_" -Tags "WARN" } finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch { Write-Information -MessageData "Write-ParallelLog: mutex release failed: $_" -Tags "WARN" }; $mutex.Dispose() } } } }
    function Invoke-NativeCommand {
        param([scriptblock]$SB)
        $o = & $SB
        return [pscustomobject]@{ Success = $LASTEXITCODE -eq 0; ExitCode = $LASTEXITCODE; Output = "$o" }
    }
    function Get-AgentServiceName {
        param([string]$Role, [int]$Index)
        $r = $Role.ToLower()
        if ($Index -eq 0) { return "oc-${r}" }
        return "oc-${r}-${Index}"
    }
    function Copy-FilesToVolume {
        param([string]$VolumeName,[hashtable[]]$Files,[string[]]$ExecCommands,[string]$Image="alpine:latest",[string]$Description)
        Write-ParallelLog "Batch seeding ${Description}: ${VolumeName} ($($Files.Count) files)"
        $Container = docker run -d --rm -v "${VolumeName}:/target" "$Image" /bin/sh -c "tail -f /dev/null" 2>$null
        if ([string]::IsNullOrWhiteSpace($Container)) {
            Write-Information -MessageData "  [FAIL] Could not create batch container for $Description" -Tags "ERROR"
            Write-ParallelLog "ERROR: Batch seeding FAILED for $Description"
            return $false
        }
        try {
            $AllOk = $true
            foreach ($File in $Files) {
                $CpResult = Invoke-NativeCommand { docker cp "$($File.Source)" "${Container}:/target/$($File.Target)" 2>&1 }
                if (-not $CpResult.Success) { $AllOk = $false }
            }
            foreach ($Cmd in $ExecCommands) {
                $ExecResult = Invoke-NativeCommand { docker exec $Container /bin/sh -c "$Cmd" 2>&1 }
                if (-not $ExecResult.Success) { $AllOk = $false }
            }
            if ($AllOk) { Write-Information -MessageData "  [OK] Batch seeded: $Description ($($Files.Count) files)" -Tags "INFO" }
            else { Write-Information -MessageData "  [WARN] Batch seeded with errors: $Description" -Tags "WARN" }
            return $AllOk
        }
        catch {
            Write-Information -MessageData "  [FAIL] Error batch seeding $Description : $($_.Exception.Message)" -Tags "ERROR"
            return $false
        }
        finally { $null = docker rm -f $Container 2>$null }
    }

    $AgentCfg = $_
    $StackName = $using:LocalStackName
    $TargetDir = $using:LocalTargetDir
    $OwnerPlaceholders = $using:LocalOwnerPlaceholders
    $SovUpper = $using:LocalSovUpper
    $RoleFileMap = $using:LocalRoleFileMap
    $SharedFiles = $using:LocalSharedFiles

    $TempFiles = [System.Collections.Generic.List[string]]::new()
    try {
        $svcName = Get-AgentServiceName -Role $AgentCfg.Role -Index $AgentCfg.Index
    $ConfigVolName = "${StackName}_agent_config_${svcName}"
    $PersistVolName = "${StackName}_agent_persist_${svcName}"
    $Role = $AgentCfg.Role
    $RoleFiles = if ($RoleFileMap.ContainsKey($Role)) { $RoleFileMap[$Role] } else { $RoleFileMap["BASE"] }

    # Create named volumes with atomic test-and-create (handles parallel race)
    $configCreated = $false
    try {
        $null = docker volume create --label com.interclaw.stack=$StackName --label com.interclaw.role=$Role --label com.interclaw.volume-type=config $ConfigVolName 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Information -MessageData "  [OK] Created volume: $ConfigVolName" -Tags "INFO"
            $configCreated = $true
        }
    } catch {
            Write-ParallelLog "WARN: Config volume create failed for $ConfigVolName : $_"
        }
    if (-not $configCreated) {
        try {
            $volCheck = docker volume ls -q -f ("name=" + $ConfigVolName) 2>$null
            if ($volCheck) {
                Write-Information -MessageData "  [SKIP] Volume already exists: $ConfigVolName (config re-seeded, data preserved)" -Tags "INFO"
            } else {
                Write-Information -MessageData "  [WARN] Volume creation failed for $ConfigVolName — may be transient error" -Tags "WARN"
                Write-ParallelLog "WARN: Could not create config volume $ConfigVolName"
            }
        } catch {
            Write-Information -MessageData "  [WARN] Volume verification failed for ${ConfigVolName}: $($_.Exception.Message)" -Tags "WARN"
            Write-ParallelLog "ERROR: Volume verification failed for ${ConfigVolName}: $($_.Exception.Message)"
        }
    }

    $persistCreated = $false
    try {
        $null = docker volume create --label com.interclaw.stack=$StackName --label com.interclaw.role=$Role --label com.interclaw.volume-type=persist $PersistVolName 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Information -MessageData "  [OK] Created volume: $PersistVolName" -Tags "INFO"
            $persistCreated = $true
        }
    } catch {
            Write-ParallelLog "WARN: Persist volume create failed for $PersistVolName : $_"
        }
    if (-not $persistCreated) {
        try {
            $volCheck = docker volume ls -q -f ("name=" + $PersistVolName) 2>$null
            if ($volCheck) {
                Write-Information -MessageData "  [SKIP] Volume already exists: $PersistVolName (user data preserved)" -Tags "INFO"
            } else {
                Write-Information -MessageData "  [WARN] Volume creation failed for $PersistVolName — may be transient error" -Tags "WARN"
                Write-ParallelLog "WARN: Could not create persist volume $PersistVolName"
            }
        } catch {
            Write-Information -MessageData "  [WARN] Volume verification failed for ${PersistVolName}: $($_.Exception.Message)" -Tags "WARN"
            Write-ParallelLog "ERROR: Volume verification failed for ${PersistVolName}: $($_.Exception.Message)"
        }
    }

    $RoleDir = Join-Path $TargetDir "Agents" $Role
    $SharedDir = Join-Path $TargetDir "Agents" "Shared"

    # --- Batch config volume seeding ---
    $ConfigFiles = [System.Collections.Generic.List[hashtable]]::new()
    $ConfigSeen = @{}`

    foreach ($File in $RoleFiles) {
        $SourcePath = Join-Path $RoleDir $File
        if (Test-Path $SourcePath) {
            $targetPath = $File
            if ($OwnerPlaceholders.Count -gt 0) {
                $content = Get-Content $SourcePath -Raw -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($content)) {
                    $resolved = $content
                    foreach ($kv in $OwnerPlaceholders.GetEnumerator()) {
                        $resolved = $resolved -replace "{$($kv.Key)}", $kv.Value
                    }
                    $tmpFile = Join-Path $env:TEMP "oc-seed-$([Guid]::NewGuid().ToString('N').Substring(0,8)).tmp"
                    [System.IO.File]::WriteAllText($tmpFile, $resolved, [System.Text.UTF8Encoding]::new($false))
                    $TempFiles.Add($tmpFile)
                    if (-not $ConfigSeen.ContainsKey($targetPath)) {
                        $ConfigSeen[$targetPath] = $true
                        $ConfigFiles.Add(@{ Source = $tmpFile; Target = $targetPath })
                    }
                    continue
                }
            }
            if (-not $ConfigSeen.ContainsKey($targetPath)) {
                $ConfigSeen[$targetPath] = $true
                $ConfigFiles.Add(@{ Source = $SourcePath; Target = $targetPath })
            }
        }
        else {
            Write-Information -MessageData "  [SKIP] File not found: $SourcePath" -Tags "INFO"
        }
    }

    foreach ($SFile in $SharedFiles) {
        $SharedPath = Join-Path $SharedDir $SFile
        if (Test-Path $SharedPath) {
            $TargetName = if ($SFile -eq "User.md") { "user.md" } else { $SFile.ToLower() }
            if (-not $ConfigSeen.ContainsKey($TargetName)) {
                $ConfigSeen[$TargetName] = $true
                if ($OwnerPlaceholders.Count -gt 0) {
                    $content = Get-Content $SharedPath -Raw -ErrorAction SilentlyContinue
                    if (-not [string]::IsNullOrWhiteSpace($content)) {
                        $resolved = $content
                        foreach ($kv in $OwnerPlaceholders.GetEnumerator()) {
                            $resolved = $resolved -replace "{$($kv.Key)}", $kv.Value
                        }
                        $tmpFile = Join-Path $env:TEMP "oc-seed-$([Guid]::NewGuid().ToString('N').Substring(0,8)).tmp"
                        [System.IO.File]::WriteAllText($tmpFile, $resolved, [System.Text.UTF8Encoding]::new($false))
                        $TempFiles.Add($tmpFile)
                        $ConfigFiles.Add(@{ Source = $tmpFile; Target = $TargetName })
                        continue
                    }
                }
                $ConfigFiles.Add(@{ Source = $SharedPath; Target = $TargetName })
            }
        }
        else {
            Write-Information -MessageData "  [SKIP] Shared file not found: $SharedPath" -Tags "INFO"
        }
    }

    if ($ConfigFiles.Count -gt 0) {
        Copy-FilesToVolume -VolumeName $ConfigVolName -Files $ConfigFiles.ToArray() `
            -ExecCommands @("chown -R 1000:1000 /target") `
            -Description "$Role config files -> $ConfigVolName ($($ConfigFiles.Count) files)"
    }
    } finally {
        foreach ($tf in $TempFiles) {
            Remove-Item $tf -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Persistence volume seeding ---
    $ExistingConfig = docker run --rm -v "${PersistVolName}:/target" alpine:latest /bin/sh -c "test -f /target/ORCHESTRATOR.json && echo EXISTS" 2>$null
    $IsFirstRun = [string]::IsNullOrWhiteSpace($ExistingConfig)

    $PersistFiles = [System.Collections.Generic.List[hashtable]]::new()
    $PersistExec = [System.Collections.Generic.List[string]]::new()

    $SovereigntyConfigSrc = Join-Path $TargetDir "Agents" $Role "$SovUpper" "ORCHESTRATOR.json"
    if (Test-Path $SovereigntyConfigSrc) {
        $PersistFiles.Add(@{ Source = $SovereigntyConfigSrc; Target = "ORCHESTRATOR.json" })
    }
    else {
        Write-Information -MessageData "  [WARN] Sovereignty config not found: $SovereigntyConfigSrc" -Tags "WARN"
        Write-ParallelLog "Sovereignty config missing for $Role/$SovUpper (may be intentional for BASE role)"
    }

    $EntrypointSrc = Join-Path $TargetDir "Infrastructure" "entrypoint.sh"
    if (Test-Path $EntrypointSrc) {
        $PersistFiles.Add(@{ Source = $EntrypointSrc; Target = "entrypoint.sh" })
    }
    else {
        Write-Information -MessageData "  [WARN] Entrypoint wrapper not found: $EntrypointSrc" -Tags "WARN"
        Write-ParallelLog "Entrypoint wrapper missing - agent will not read Docker secrets"
    }

    $HasPersistedEntrypoint = Test-Path $EntrypointSrc

    if ($IsFirstRun) {
        $MemorySrc = Join-Path $RoleDir "memory.md"
        if (Test-Path $MemorySrc) {
            $PersistFiles.Add(@{ Source = $MemorySrc; Target = "memory.md" })
        }

        $BootstrapSrc = Join-Path $RoleDir "bootstrap.md"
        if (Test-Path $BootstrapSrc) {
            $PersistFiles.Add(@{ Source = $BootstrapSrc; Target = "workspace/bootstrap.md" })
        }
    }

    if ($HasPersistedEntrypoint) {
        $PersistExec.Add("sed -i 's/\r$//' /target/entrypoint.sh && chmod +x /target/entrypoint.sh")
    }
    $PersistExec.Add("mkdir -p /target/workspace /target/workspace/deliverables /target/workspace/deliverables/Trash")
    $PersistExec.Add("chown -R 1000:1000 /target")

    if ($PersistFiles.Count -gt 0) {
        Copy-FilesToVolume -VolumeName $PersistVolName -Files $PersistFiles.ToArray() `
            -ExecCommands $PersistExec.ToArray() `
            -Description "$Role persist files -> $PersistVolName ($($PersistFiles.Count) files)"
    }

    if ($IsFirstRun) {
        Write-Information -MessageData "  [FIRST-RUN] Persistence volume initialized for $($AgentCfg.AgentName)" -Tags "INFO"
        Write-ParallelLog "First-run persistence seed for $($AgentCfg.AgentName)"
    }
    else {
        Write-Information -MessageData "  [PERSIST] Preserving existing data for $($AgentCfg.AgentName)" -Tags "INFO"
        Write-ParallelLog "Preserving existing persistence data for $($AgentCfg.AgentName)"
    }

    Write-Information -MessageData "  [OK] Agent $($AgentCfg.AgentName): volumes initialized." -Tags "INFO"
    Write-ParallelLog "Agent $($AgentCfg.AgentName) volumes seeded ($Role, config=$($ConfigFiles.Count) files, persist=$PersistVolName)"
    } finally {
        $PSDefaultParameterValues = $__savedPSDefault
    }
} -ThrottleLimit 3

# Create shared memory volume for multi-agent setups
if ($AgentConfigs.Count -gt 1) {
    $MemSharedVolName = "${StackName}_memory_shared"
    $MemSharedVol = docker volume ls -q -f "name=$MemSharedVolName" 2>$null
    if (-not $MemSharedVol) {
        $null = docker volume create --label com.interclaw.stack=$StackName --label com.interclaw.volume-type=memory-shared $MemSharedVolName
        Write-Information -MessageData "  [OK] Created shared memory volume: $MemSharedVolName" -Tags "INFO"
    }
    else {
        Write-Information -MessageData "  [SKIP] Shared memory volume already exists: memory_shared" -Tags "INFO"
    }
}

# Create shared workspace volume for repo sharing between agents and CODE containers
$WorkspaceVolName = "${StackName}_interclaw_workspace"
$WorkspaceVol = docker volume ls -q -f "name=$WorkspaceVolName" 2>$null
if (-not $WorkspaceVol) {
    $null = docker volume create --label com.interclaw.stack=$StackName --label com.interclaw.volume-type=workspace $WorkspaceVolName
    Write-Information -MessageData "  [OK] Created shared workspace volume: $WorkspaceVolName" -Tags "INFO"
    Write-SetupLog "Created shared workspace volume: $WorkspaceVolName"
}
else {
    Write-Information -MessageData "  [SKIP] Shared workspace volume already exists: $WorkspaceVolName" -Tags "INFO"
}

# Create Zoho token cache volume for cross-process OAuth access token persistence
$ZohoCacheVolName = "${StackName}_zoho_token_cache"
$ZohoCacheVol = docker volume ls -q -f "name=$ZohoCacheVolName" 2>$null
if (-not $ZohoCacheVol) {
    $null = docker volume create --label com.interclaw.stack=$StackName --label com.interclaw.volume-type=cache --label com.interclaw.service=zoho $ZohoCacheVolName
    Write-Information -MessageData "  [OK] Created Zoho token cache volume: $ZohoCacheVolName" -Tags "INFO"
}
else {
    Write-Information -MessageData "  [SKIP] Zoho token cache volume already exists: $ZohoCacheVolName" -Tags "INFO"
}

# Clone workspace repos using GitHub token (if configured)
if (-not [string]::IsNullOrWhiteSpace($WorkspaceRepos)) {
    Write-Information -MessageData "`n[WorkspaceRepos] Cloning shared repositories into $WorkspaceVolName..." -Tags "INFO"
    Write-SetupLog "WorkspaceRepos: cloning into $WorkspaceVolName"

    $GithubToken = $null
    if (Get-Command Get-SecretFromAws -ErrorAction SilentlyContinue) {
        $GithubToken = Get-SecretFromAws -KeyName "GITHUB_TOKEN_READALL"
    }
    if ([string]::IsNullOrWhiteSpace($GithubToken)) {
        Write-SetupLog "WorkspaceRepos: GITHUB_TOKEN_READALL not found - cloning anonymously (private repos will fail with 403)" -Level WARN
        Write-Information -MessageData "  [WARN] GITHUB_TOKEN_READALL not found - repos requiring auth will fail" -Tags "WARN"
    }

    $RepoList = $WorkspaceRepos -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($RepoList.Count -gt 0) {
        Write-Information -MessageData "`n[WorkspaceRepos] Cloning $($RepoList.Count) repositories into $WorkspaceVolName..." -Tags "INFO"
        Write-SetupLog "WorkspaceRepos: cloning $($RepoList.Count) repos into $WorkspaceVolName"
        Write-ParallelSectionHeader -Title "Clone Repositories" -Workers ($RepoList | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) })

        Write-Information -MessageData "  [ ..] Pulling alpine/git:latest image..." -Tags "WARN"
        Write-SetupLog "WorkspaceRepos: pulling alpine/git:latest"
        $pullOutput = docker pull alpine/git:latest 2>&1
        $pullExit = $LASTEXITCODE
        if ($pullExit -ne 0) {
            throw "Failed to pull alpine/git:latest — cannot proceed with volume seeding. Exit code: $pullExit"
        }
        else {
            Write-Information -MessageData "  [OK] alpine/git:latest available" -Tags "INFO"
        }
    }

    $cloneErrors = $RepoList | ForEach-Object -Parallel {
        $__savedPSDefault2 = $PSDefaultParameterValues
        try {
            $RepoUrl = $_
            $RepoName = [System.IO.Path]::GetFileNameWithoutExtension($RepoUrl)
            $WorkspaceVolName = $using:WorkspaceVolName
            $GithubToken = $using:GithubToken
            $MaxRetries = 3
            $RetryDelays = @(2, 5, 10)

            $SafeDirCmd = "git -c safe.directory='*'"
            $CloneCmd = "mkdir -p /workspace && cd /workspace"
            if (-not [string]::IsNullOrWhiteSpace($GithubToken)) {
                $AuthenticatedUrl = $RepoUrl.Replace("https://github.com/", "https://$GithubToken@github.com/")
                $CloneCmd += " && if [ -d '$RepoName/.git' ]; then cd '$RepoName' && ${SafeDirCmd} pull --ff-only; else ${SafeDirCmd} clone '$AuthenticatedUrl' '$RepoName'; fi"
            }
            else {
                $CloneCmd += " && if [ -d '$RepoName/.git' ]; then cd '$RepoName' && ${SafeDirCmd} pull --ff-only; else ${SafeDirCmd} clone '$RepoUrl' '$RepoName'; fi"
            }

            $exitCode = -1
            $output = $null
            $lastError = $null
            function Get-BackoffDelay { param($Attempt) [math]::Min(30, [math]::Pow(2, $Attempt) * 1) }
            for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
                if ($attempt -gt 0) {
                    $delay = Get-BackoffDelay -Attempt ($attempt + 1)
                    Start-Sleep -Seconds $delay
                    Write-Information -MessageData "  [RETRY] ${RepoName}: attempt $($attempt + 1)/$($MaxRetries + 1)" -Tags "WARN"
                }

                $output = docker run --rm --entrypoint /bin/sh -v "${WorkspaceVolName}:/workspace" "alpine/git:latest" -c "$CloneCmd" 2>&1
                $exitCode = $LASTEXITCODE
                if ($exitCode -eq 0) {
                    return $null
                }
                $lastError = @{ Repo = $RepoName; ExitCode = $exitCode; Output = "$output"; Attempt = $attempt + 1 }
            }

            # All retries exhausted -- check if stale .git dir exists
            $checkStale = docker run --rm --entrypoint /bin/sh -v "${WorkspaceVolName}:/workspace" "alpine/git:latest" -c "if [ -d '$RepoName/.git' ]; then echo 'exists'; fi" 2>$null
            if ($checkStale -match 'exists') {
                Write-Information -MessageData "  [WARN] ${RepoName}: all retries failed but .git exists - keeping stale clone" -Tags "WARN"
                return $null
            }

            return $lastError
        } finally {
            $PSDefaultParameterValues = $__savedPSDefault2
        }
    } -ThrottleLimit 4

    $cloneErrors = $cloneErrors | Where-Object { $_ -ne $null }
    $repoNames = $RepoList | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) }
    $cloneSummary = foreach ($repoName in $repoNames) {
        $err = $cloneErrors | Where-Object { $_.Repo -eq $repoName } | Select-Object -First 1
        if ($err) {
            Write-SetupLog "WorkspaceRepos: $($err.Repo) clone/pull exited $($err.ExitCode)`n$($err.Output)" -Level WARN
            Write-Information -MessageData "  [WARN] $($err.Repo): exit $($err.ExitCode)" -Tags "WARN"
            Write-Information -MessageData "    $($err.Output)" -Tags "INFO"
            @{ Name = $repoName; Status = "WARN"; Detail = "exit $($err.ExitCode)" }
        } else {
            @{ Name = $repoName; Status = "OK"; Detail = "cloned/pulled" }
        }
    }
    if ($cloneErrors.Count -eq 0) {
        Write-Information -MessageData "  [OK] All $($RepoList.Count) repositories cloned/pulled." -Tags "INFO"
    }
    else {
        Write-Information -MessageData "  [WARN] $($cloneErrors.Count)/$($RepoList.Count) repositories failed to clone/pull" -Tags "WARN"
    }
    Write-ParallelSectionSummary -Title "Clone Repositories" -Results $cloneSummary
`
    # Fix workspace permissions so node user (1000) can write
    Write-Information -MessageData "  [ ..] Fixing workspace volume permissions..." -Tags "WARN"
    $null = docker run --rm -v "${WorkspaceVolName}:/workspace" alpine:latest chown -R 1000:1000 /workspace 2>&1
    Write-Information -MessageData "  [OK] Workspace permissions fixed (chown 1000:1000)." -Tags "INFO"
}

# Ensure host directories for bind mounts exist (used by BASE container)
$orchOutboxDir = Join-Path $TargetDir "workspace" "ORCH Outbox"
if (-not (Test-Path -LiteralPath $orchOutboxDir)) {
    $null = New-Item -ItemType Directory -Path $orchOutboxDir -Force
    Write-Information -MessageData "  [OK] Created host directory: $orchOutboxDir" -Tags "INFO"
}

Write-SetupLog "Phase 2 complete: volumes created and seeded"
}

