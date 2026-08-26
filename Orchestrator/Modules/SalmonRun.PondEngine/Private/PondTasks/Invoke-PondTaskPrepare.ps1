function Invoke-PondTaskPrepare {
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
    foreach ($file in $files) {
        $src = $file.FullName
        if (-not (Test-Path -LiteralPath $src)) { continue }

        $streamId = if ($group.Stream) { $group.Stream.Id } else { 'main' }
        $null = Add-PlanPondLog -PlanPath $src -Entry @{
            ts     = (Get-Date -Format 'o')
            pond   = $Pond.Name
            role   = 'planner'
            action = 'lock'
            detail = "acquired lock in lane $($group.LaneId) on stream $streamId"
            lane   = $group.LaneId
            stream = $streamId
            agent  = 'PondEngine'
        } -ErrorAction Stop
    }

    return $Context
}
