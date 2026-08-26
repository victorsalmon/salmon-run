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

    $command = if ($Task.Arguments.Command) { $Task.Arguments.Command } else { "work-$($Pond.Role)-once" }
    $command = $command -replace '\{role\}', $Pond.Role

    $spawnFile = Join-Path $lanePath '.spawn'
    $runFile = Join-Path $lanePath '.run'
    $model = if ($Context.Config) { $Context.Config | ConvertTo-Json -Depth 2 -Compress } else { '{}' }

    @{
        Command  = $command
        Role     = $Pond.Role
        Pond     = $Pond.Name
        Lane     = $group.LaneId
        Stream   = $group.Stream.Id
        Model    = $model
        Spawned  = (Get-Date -Format 'o')
    } | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $spawnFile -Encoding utf8 -NoNewline

    # Write a placeholder .run file that a real harness would replace with the
    # actual agent invocation. The monitor waits for .complete.
    "# $command" | Set-Content -LiteralPath $runFile -Encoding utf8 -NoNewline

    Write-Verbose "Invoke-PondTaskSpawnAgent: spawned '$command' for '$($group.Namespace)' in lane '$($group.LaneId)'"
    return $Context
}
