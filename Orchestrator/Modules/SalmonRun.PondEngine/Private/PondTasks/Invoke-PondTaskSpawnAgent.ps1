function Invoke-PondTaskSpawnAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondTask]$Task,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    $group = $Context.CurrentGroup
    if (-not $group) { $Context.Continue = $false; return $Context }

    $lanePath = $group.StreamPath
    if ([string]::IsNullOrWhiteSpace($lanePath)) {
        $Context.Continue = $false
        return $Context
    }

    $files = @(Get-ChildItem "$lanePath/*.md" -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { $Context.Continue = $false; return $Context }

    $planPaths = $files | Select-Object -ExpandProperty FullName

    # Resolve the executor profile. Fall back to a generic opencode profile if
    # the model router has not been run yet.
    $profile = if ($Context.Config -is [PondExecutionProfile]) {
        $Context.Config
    } else {
        Resolve-PondExecutionProfile -Tier 'Daily' -PlanFiles $planPaths
    }

    $command = Get-PondExecutorCommand -Profile $profile -Role $Pond.Role -RepoDir $Context.RepoDir -PlanFiles $planPaths

    $spawnFile = Join-Path $lanePath '.spawn'
    @{
        Role      = $Pond.Role
        Pond      = $Pond.Name
        Lane      = $group.LaneId
        Stream    = if ($group.Stream) { $group.Stream.Id } else { 'main' }
        Profile   = ($profile | Select-Object Tier, Harness, Provider, Model, Effort, Cli, ExecutorFile | ConvertTo-Json -Compress -Depth 2)
        Command   = $command.Command
        Spawned   = (Get-Date -Format 'o')
    } | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $spawnFile -Encoding utf8 -NoNewline

    # The .run file is the canonical harness invocation record.
    $logPath = Join-Path $Context.TaskRoot 'Logs' "pond-executor-$($group.LaneId).log"
    $null = New-Item -ItemType Directory -Path (Split-Path $logPath -Parent) -Force -ErrorAction SilentlyContinue
    $null = Start-PondExecutor -Command $command -LanePath $lanePath -LogPath $logPath

    Write-Verbose "Invoke-PondTaskSpawnAgent: prepared '$($command.Command)' for '$($group.Namespace)' in lane '$($group.LaneId)'"
    return $Context
}
