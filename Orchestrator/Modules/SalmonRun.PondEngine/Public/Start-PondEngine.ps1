#Requires -Version 7.0

<#
.SYNOPSIS
    Runs the salmon-run workflow as a pipeline of generalizable ponds.
.DESCRIPTION
    Start-PondEngine is the next-generation orchestrator entry point.
    It reads a list of Pond objects, dispatches each through its configured
    task pipeline, and transitions plans between ponds on success or failure.
    This function is opt-in from Start-Orchestrator via -UsePondEngine.
.PARAMETER Ponds
    Optional. An array of Pond objects. Defaults to Get-SalmonRunPonds.
.PARAMETER RepoDir
    Optional. Repository root. Defaults to the salmon-run repo root.
.PARAMETER MaxIterations
    Maximum main-loop iterations. Default 20.
.PARAMETER SubprocessTimeoutMinutes
    Maximum minutes a single agent subprocess may run. Default 30.
.PARAMETER PollIntervalSeconds
    Seconds to sleep when no work is available. Default 300.
.PARAMETER Streams
    Optional. An array of PondStream objects. Defaults to a single main-branch
    stream with the default operator layout.
#>
function Start-PondEngine {
    [CmdletBinding()]
    param(
        [Pond[]]$Ponds = (Get-SalmonRunPonds),
        [string]$RepoDir = (Get-SalmonRunRepoRoot),
        [int]$MaxIterations = 20,
        [int]$SubprocessTimeoutMinutes = 30,
        [int]$PollIntervalSeconds = 300,
        [PondStream[]]$Streams = (New-PondStream -Id 'stream-1' -Branch 'main' -Path $RepoDir)
    )

    $context = [PondContext]::new()
    $context.RepoDir = $RepoDir
    $context.ActiveStreams = @{}
    $context.UsedNamespaces = @{}
    $context.BusyNamespaces = @{}
    $context.Streams = [System.Collections.ArrayList]::new()
    foreach ($s in $Streams) { $null = $context.Streams.Add($s) }
    $context.CrashHistory = [System.Collections.Generic.List[datetime]]::new()
    $context.Iteration = 0
    $context.Counts = $null

    Write-Host "Starting PondEngine for $RepoDir" -ForegroundColor Cyan

    for ($context.Iteration = 1; $context.Iteration -le $MaxIterations; $context.Iteration++) {
        $context.Counts = Get-TaskCounts
        $didWork = $false

        foreach ($pond in $Ponds) {
            $context.CurrentPond = $pond
            if (-not $pond.Entry.Enabled) { continue }

            # TODO: implement full pipeline
            Write-Verbose "PondEngine: evaluating pond '$($pond.Name)'"
        }

        if (-not $didWork) {
            Write-Verbose "PondEngine: no work, sleeping ${PollIntervalSeconds}s"
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }

    Write-Host "PondEngine finished after $($context.Iteration) iterations" -ForegroundColor Cyan
}
