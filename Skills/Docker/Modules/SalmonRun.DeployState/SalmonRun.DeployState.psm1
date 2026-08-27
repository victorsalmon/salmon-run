#Requires -Version 7.0
<#
.SYNOPSIS
    Deployment state management ├óΓé¼ΓÇ¥ error tracking, checkpoints, phase orchestration.
.DESCRIPTION
    Maintains a list of setup/ deploy errors collected across phases and provides
    checkpoint/resume support for the deploy.ps1 orchestrator.
#>
Set-StrictMode -Off

$script:InterclawErrors = [System.Collections.Generic.List[hashtable]]::new()
$script:SetupPhasesCompleted = [System.Collections.Generic.List[string]]::new()

function ConvertFrom-PSCustomObjectToHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return @{} }
    if ($InputObject -is [array]) {
        return @($InputObject | ForEach-Object { ConvertFrom-PSCustomObjectToHashtable $_ })
    }
    if ($InputObject -is [PSCustomObject]) {
        $ht = @{}
        $InputObject.PSObject.Properties | ForEach-Object {
            $ht[$_.Name] = ConvertFrom-PSCustomObjectToHashtable $_.Value
        }
        return $ht
    }
    return $InputObject
}

<#
.SYNOPSIS
    Records a setup error with phase, category, and recoverability flag.
.DESCRIPTION
    Adds an error entry to the global error list and logs it via Write-SetupLog
    at the appropriate severity level. Recoverable errors produce WARN-level
    logs; fatal errors produce ERROR-level.
.PARAMETER Phase
    Setup phase name where the error occurred.
.PARAMETER Message
    Human-readable error description.
.PARAMETER Category
    Error category for grouping and triage.
.PARAMETER Recoverable
    If true, logged as WARN and will appear in deferred tasks rather than blocking.
#>
function Add-SetupError {
    param(
        [Parameter(Mandatory)]
        [string]$Phase,
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("Phase", "Prerequisite", "AWS", "Docker", "Secrets", "Network", "Resource")]
        [string]$Category = "Phase",
        [bool]$Recoverable = $false
    )
    $entry = @{
        Phase       = $Phase
        Message     = $Message
        Category    = $Category
        Recoverable = $Recoverable
        Timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    $script:InterclawErrors.Add($entry)
    $level = if ($Recoverable) { "WARN" } else { "ERROR" }
    $tag = if ($Recoverable) { "RECOVERABLE" } else { "FATAL" }
    Write-SetupLog "[$Phase] ${tag}: $Message" -Level $level
}

<#
.SYNOPSIS
    Exports setup errors to a markdown report and tasks review file.
.DESCRIPTION
    Generates a timestamped markdown report in Tasks/Logs/ and a
    reviewer-ready file in Tasks/Review/ with error tables grouped by phase.
    Includes a deferred human tasks section for recoverable errors.
.PARAMETER ReportLabel
    Label for the report filename (default: setup-errors).
#>
function Export-SetupErrors {
    [CmdletBinding()]
    param(
        [string]$ReportLabel = "setup-errors"
    )
    if ($script:InterclawErrors.Count -eq 0) { return }

    $Date = Get-Date -Format "yyyy.MM.dd-HHmmss"
    $ReportsDir = Get-ReportsDir
    $TasksDir = Get-SalmonTaskRoot

    $MarkdownPath = Join-Path $ReportsDir "$Date-$ReportLabel.md"
    $TasksFilePath = Join-Path (Join-Path $TasksDir "Logs") "$Date-$ReportLabel.md"

    $recoverableCount = @($script:InterclawErrors | Where-Object { $_.Recoverable }).Count
    $fatalCount = $script:InterclawErrors.Count - $recoverableCount

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("---")
    $lines.Add("date: $Date")
    $lines.Add("run_id: $env:INTERCLAW_RUN_ID")
    $lines.Add("status: ready")
    $lines.Add("---")
    $lines.Add("")
    $lines.Add("# Setup Errors - $Date")
    $lines.Add("")
    $lines.Add("Run ID: ``$env:INTERCLAW_RUN_ID``")
    $lines.Add("")

    if ($script:SetupPhasesCompleted.Count -gt 0) {
        $lines.Add("## Phases Completed")
        $lines.Add("")
        foreach ($p in $script:SetupPhasesCompleted) {
            $lines.Add("- $p")
        }
        $lines.Add("")
    }

    if ($script:InterclawErrors.Count -gt 0) {
        $lines.Add("## Error Summary")
        $lines.Add("")
        $lines.Add("| Severity | Count |")
        $lines.Add("|----------|-------|")
        $lines.Add("| Fatal | $fatalCount |")
        $lines.Add("| Recoverable | $recoverableCount |")
        $lines.Add("| **Total** | **$($script:InterclawErrors.Count)** |")
        $lines.Add("")

        $phases = $script:InterclawErrors | Group-Object Phase
        foreach ($pg in $phases) {
            $lines.Add("### Phase: $($pg.Name)")
            $lines.Add("")
            $lines.Add("| Timestamp | Category | Severity | Message |")
            $lines.Add("|-----------|----------|----------|---------|")
            foreach ($e in $pg.Group) {
                $sev = if ($e.Recoverable) { "WARN" } else { "FAIL" }
                $lines.Add("| $($e.Timestamp) | $($e.Category) | $sev | $($e.Message) |")
            }
            $lines.Add("")
        }

        $deferred = @($script:InterclawErrors | Where-Object { $_.Recoverable })
        if ($deferred.Count -gt 0) {
            $lines.Add("## Deferred Human Tasks")
            $lines.Add("")
            $lines.Add("The following issues were recoverable and require manual action:")
            $lines.Add("")
            foreach ($d in $deferred) {
                $lines.Add("1. **[$($d.Category)]** $($d.Message)")
            }
            $lines.Add("")
            $lines.Add("After resolving, re-run deploy.ps1 to pick up where you left off.")
        }
    } else {
        $lines.Add("All phases completed successfully.")
    }

    $body = $lines -join "`r`n"
    $body | Write-AtomicFile -Path $MarkdownPath -Encoding UTF8
    Write-SetupLog "Wrote error report: $MarkdownPath"

    $LogsDir = Split-Path $TasksFilePath -Parent
    if (-not (Test-Path $LogsDir)) { $null = New-Item -ItemType Directory -Path $LogsDir -Force }
    $body | Write-AtomicFile -Path $TasksFilePath -Encoding UTF8
    Write-SetupLog "Wrote tasks file: $TasksFilePath"
}

<#
.SYNOPSIS
    Creates a task file in Tasks/Logs/ from the current setup errors.
.DESCRIPTION
    Generates a reviewer-ready markdown file with setup errors grouped by
    phase, suitable for driving follow-up remediation tasks.
    Only produces output when errors exist.
#>
function New-SetupErrorsTasksFile {
    [CmdletBinding()]
    param()
    if ($script:InterclawErrors.Count -eq 0) { return }

    $Date = Get-Date -Format "yyyy.MM.dd-HHmmss"
    $LogsDir = Join-Path (Get-SalmonTaskRoot) "Logs"
    if (-not (Test-Path $LogsDir)) { $null = New-Item -ItemType Directory -Path $LogsDir -Force }
    $TaskPath = Join-Path $LogsDir "$Date-setup-errors.md"

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("date: $Date")
    $null = $sb.AppendLine("run_id: $env:INTERCLAW_RUN_ID")
    $null = $sb.AppendLine("status: ready")
    $null = $sb.AppendLine("---")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("# Setup Errors - $Date")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("Total errors: $($script:InterclawErrors.Count)")
    $null = $sb.AppendLine("")

    $byPhase = $script:InterclawErrors | Group-Object Phase
    foreach ($pg in $byPhase) {
        $null = $sb.AppendLine("## Phase: $($pg.Name)")
        $null = $sb.AppendLine("")
        $null = $sb.AppendLine("| Category | Severity | Message |")
        $null = $sb.AppendLine("|----------|----------|---------|")
        foreach ($e in $pg.Group) {
            $sev = if ($e.Recoverable) { "WARN" } else { "FAIL" }
            $null = $sb.AppendLine("| $($e.Category) | $sev | $($e.Message) |")
        }
        $null = $sb.AppendLine("")
    }

    $deferred = @($script:InterclawErrors | Where-Object { $_.Recoverable })
    if ($deferred.Count -gt 0) {
        $null = $sb.AppendLine("## Deferred Human Tasks")
        $null = $sb.AppendLine("")
        foreach ($d in $deferred) {
            $null = $sb.AppendLine("1. **[$($d.Category)]** $($d.Message)")
        }
        $null = $sb.AppendLine("")
        $null = $sb.AppendLine("After resolving, re-run deploy.ps1 to continue.")
    }

    $sb.ToString() | Write-AtomicFile -Path $TaskPath -Encoding UTF8
    Write-SetupLog "Wrote error tasks file: $TaskPath"
}

<#
.SYNOPSIS
    Writes a named checkpoint to the checkpoint file for resume support.
.DESCRIPTION
    Persists a completion checkpoint under the current run ID in a JSON file
    at ~/.ORCHESTRATOR/checkpoints.json. Uses a named mutex for concurrency safety
    across parallel setup phases. Checkpoints survive setup restarts.
.PARAMETER Name
    Unique checkpoint name (typically the phase or step identifier).
#>
function Set-SetupCheckpoint {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    $runId = $env:INTERCLAW_RUN_ID
    if ([string]::IsNullOrWhiteSpace($runId)) { return }
    $homeDir = Get-HomeDir
    $checkpointDir = Join-Path $homeDir ".ORCHESTRATOR"
    $checkpointFile = Join-Path $checkpointDir "checkpoints.json"

    $mtx = New-Object System.Threading.Semaphore(1, 1, "Global\Interclaw-Checkpoint-Mutex")
    if (-not $mtx.WaitOne(10000)) {
        $mtx.Dispose()
        throw "Set-SetupCheckpoint: Mutex timeout after 10000ms -- concurrent access detected"
    }

    try {
        $checkpoints = @{}
        if (Test-Path $checkpointFile) {
            try { $checkpoints = ConvertFrom-PSCustomObjectToHashtable (Get-Content -LiteralPath $checkpointFile -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { Write-Debug "Set-SetupCheckpoint: Failed to read checkpoints: $_"; $checkpoints = @{} }
        }
        if (-not $checkpoints.ContainsKey($runId)) { $checkpoints[$runId] = @{} }
        $checkpoints[$runId][$Name] = @{ Status = "complete"; Timestamp = Get-Date -Format "o" }

        $null = New-Item -ItemType Directory -Path (Split-Path $checkpointFile -Parent) -Force
        $checkpoints | Write-AtomicJson -Path $checkpointFile -Depth 5
    } finally {
        $null = $mtx.Release()
        $mtx.Dispose()
    }
}

<#
.SYNOPSIS
    Checks whether a named checkpoint exists for the current run.
.DESCRIPTION
    Reads the checkpoint file and returns true if the given checkpoint name
    is found under the current run ID. Returns false if no checkpoint file
    exists or the checkpoint is absent.
.PARAMETER Name
    Checkpoint name to test for completion.
#>
function Test-SetupCheckpoint {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    $runId = $env:INTERCLAW_RUN_ID
    if ([string]::IsNullOrWhiteSpace($runId)) { return $false }
    $homeDir = Get-HomeDir
    $checkpointFile = Join-Path (Join-Path $homeDir ".ORCHESTRATOR") "checkpoints.json"
    if (-not (Test-Path $checkpointFile)) { return $false }

    $mtx = New-Object System.Threading.Semaphore(1, 1, "Global\Interclaw-Checkpoint-Mutex")
    if (-not $mtx.WaitOne(10000)) {
        $mtx.Dispose()
        Write-Warning "Test-SetupCheckpoint: Mutex timeout after 10000ms ΓÇö returning false"
        return $false
    }
    try {
        $checkpoints = ConvertFrom-PSCustomObjectToHashtable (Get-Content -LiteralPath $checkpointFile -Raw -ErrorAction Stop | ConvertFrom-Json)
        return $checkpoints.ContainsKey($runId) -and $checkpoints[$runId].ContainsKey($Name)
    } catch { return $false }
    finally { $null = $mtx.Release(); $mtx.Dispose() }
}

<#
.SYNOPSIS
    Removes all checkpoints for a given run ID from the checkpoint file.
.DESCRIPTION
    Deletes the specified run's checkpoint entries. If no checkpoints remain
    after removal, deletes the checkpoint file entirely. Uses a mutex for
    concurrency safety.
.PARAMETER RunId
    Run ID whose checkpoints to clear (defaults to $env:INTERCLAW_RUN_ID).
#>
function Clear-SetupCheckpoints {
    [CmdletBinding()]
    param(
        [string]$RunId = $env:INTERCLAW_RUN_ID
    )
    if ([string]::IsNullOrWhiteSpace($RunId)) { return }
    $homeDir = Get-HomeDir
    $checkpointFile = Join-Path (Join-Path $homeDir ".ORCHESTRATOR") "checkpoints.json"
    if (-not (Test-Path $checkpointFile)) { return }

    $mtx = New-Object System.Threading.Semaphore(1, 1, "Global\Interclaw-Checkpoint-Mutex")
    if (-not $mtx.WaitOne(10000)) {
        $mtx.Dispose()
        throw "Clear-SetupCheckpoints: Mutex timeout after 10000ms -- concurrent access detected"
    }
    try {
        $checkpoints = @{}
        try { $checkpoints = ConvertFrom-PSCustomObjectToHashtable (Get-Content -LiteralPath $checkpointFile -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { Write-Debug "Clear-SetupCheckpoints: Failed to read checkpoints: $_"; return }
        $countBefore = $checkpoints.Count
        $checkpoints.Remove($RunId) | Out-Null
        if ($checkpoints.Count -lt $countBefore) {
            if ($checkpoints.Count -eq 0) {
                Remove-Item -LiteralPath $checkpointFile -Force -ErrorAction SilentlyContinue
            } else {
                $checkpoints | Write-AtomicJson -Path $checkpointFile -Depth 5
            }
            Write-SetupLog "Cleared checkpoints for run $RunId"
        }
    } finally {
        $null = $mtx.Release()
        $mtx.Dispose()
    }
}

<#
.SYNOPSIS
    Runs a deployment phase with checkpoint/resume support.
.DESCRIPTION
    Checks whether the phase checkpoint already exists (skips if so), executes
    the script block, records the phase as completed, and persists a checkpoint
    on success. On error, records via Add-SetupError and re-throws if fatal.
.PARAMETER Phase
    Phase name for checkpointing and error tracking.
.PARAMETER ScriptBlock
    Script block to execute for the phase.
.PARAMETER Recoverable
    If true, errors are logged as recoverable and execution continues.
#>
function Invoke-DeployStatePhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Phase,
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [switch]$Recoverable
    )
    $__checked = @(Test-SetupCheckpoint -Name $Phase)[-1]
    if ($__checked) {
        Write-SetupLog "Skipping phase [$Phase] -- already complete" -Level DEBUG
        return
    }
    Write-Information "`n[PHASE] $Phase..."
    Write-SetupLog "Phase starting: $Phase"

    try {
        & $ScriptBlock
        $script:SetupPhasesCompleted.Add($Phase)
        Set-SetupCheckpoint -Name $Phase
        Write-SetupLog "Phase complete: $Phase"
    }
    catch {
        $msg = "$($_.Exception.Message)"
        Add-SetupError -Phase $Phase -Message $msg -Recoverable:$Recoverable
        if (-not $Recoverable) {
            throw "Fatal error in phase [$Phase]: $msg"
        }
    }
}

<#
.SYNOPSIS
    Cleans up elevated credentials, AWS SSO tokens, and orphan Docker secrets.
.DESCRIPTION
    Scrubs AWS SSO token caches, clears sensitive process environment variables,
    and removes orphan TEST-* Docker Swarm secrets. Called during deploy cleanup phases.
.PARAMETER HomeDir
    Home directory path (defaults to Get-HomeDir).
.PARAMETER DryRun
    If set, logs what would be cleaned without actually removing.
#>
function Invoke-CredentialCleanup {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$HomeDir = (Get-HomeDir),
        [switch]$DryRun
    )

    Write-Warning "`n[CLEANUP] Scrubbing elevated credentials..."
    Write-SetupLog "Phase 14: Credential cleanup"

    $cliCache = Join-Path $HomeDir ".aws/cli/cache"
    if (Test-Path $cliCache) {
        Get-ChildItem $cliCache -Filter "*.json" | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Verbose "  [OK] Cleared AWS SSO token cache."
        Write-SetupLog "Cleared AWS SSO token cache"
    }

    $ssoCache = Join-Path $HomeDir ".aws/sso/cache"
    if (Test-Path $ssoCache) {
        Get-ChildItem $ssoCache -Filter "*.json" | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Verbose "  [OK] Cleared AWS SSO access tokens."
        Write-SetupLog "Cleared AWS SSO access tokens"
    }

    $sensitive = @(
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
        "AWS_SECURITY_TOKEN", "AWS_SECRET", "ORCHESTRATOR_SECRETS_JSON",
        "TELEGRAM_BOT_TOKEN_ORCH", "TELEGRAM_OWNER_USERNAME", "TELEGRAM_OWNER_USERID",
        "SALMON_GATEWAY_TOKEN"
    )
    foreach ($var in $sensitive) {
        if (Get-Item -Path "Env:\$var" -ErrorAction SilentlyContinue) {
            Set-Item -Path "Env:\$var" -Value ""
            Remove-Item -Path "Env:\$var" -ErrorAction SilentlyContinue
        }
    }
    Write-Verbose "  [OK] Cleared sensitive process environment variables."
    Write-SetupLog "Cleared sensitive env vars"

    # Clean up orphan TEST-* secrets from Docker Swarm
    $__orphanSecrets = Invoke-Docker secret ls --filter name=TEST- -q 2>$null
    if ($__orphanSecrets) {
        $__refdServices = Invoke-Docker service ls --format "{{.Name}}" 2>$null
        foreach ($__secretId in $__orphanSecrets) {
            $__secretName = Invoke-Docker secret inspect $__secretId --format "{{.Spec.Name}}" 2>$null
            $__inUse = $false
            foreach ($__svc in $__refdServices) {
                $__svcSecrets = Invoke-Docker service inspect $__svc --format "{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{.SecretName}} {{end}}" 2>$null
                if ($__svcSecrets -and $__svcSecrets -match $__secretName) { $__inUse = $true; break }
            }
            if (-not $__inUse) {
                if ($DryRun) {
                    Write-SetupLog "[DRY-RUN] Would remove orphan TEST secret: $__secretName" -Level INFO
                } else {
                    Invoke-Docker secret rm $__secretId 2>$null
                    Write-SetupLog "Removed orphan TEST secret: $__secretName" -Level INFO
                }
            }
        }
    }
}

Set-Alias -Name Invoke-SetupPhase -Value Invoke-DeployStatePhase

<#
.SYNOPSIS
    Clears accumulated deploy state for testing and fresh-start scenarios.
#>
function Clear-DeployState {
    $script:InterclawErrors = [System.Collections.Generic.List[hashtable]]::new()
    $script:SetupPhasesCompleted = [System.Collections.Generic.List[string]]::new()
}

Export-ModuleMember -Function @(
    'Add-SetupError',
    'Export-SetupErrors',
    'Set-SetupCheckpoint',
    'Test-SetupCheckpoint',
    'Clear-SetupCheckpoints',
    'New-SetupErrorsTasksFile',
    'Invoke-DeployStatePhase',
    'Invoke-CredentialCleanup',
    'Clear-DeployState',
    'ConvertFrom-PSCustomObjectToHashtable'
)
Export-ModuleMember -Alias 'Invoke-SetupPhase'

