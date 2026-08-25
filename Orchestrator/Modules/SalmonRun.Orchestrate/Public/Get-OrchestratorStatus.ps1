<#
.SYNOPSIS
    Returns the current orchestrator status and queue state.
.DESCRIPTION
    Reports task counts across all queues (Code, Review, Working), active stream
    information, and fleet agent status. Combines output from Get-TaskCounts and
    Get-AgentFleetStatus into a single status object.
.PARAMETER AsTable
    If set, writes a formatted status table to the console instead of returning objects.
.OUTPUTS
    PSCustomObject with queue counts, active streams, and fleet agent status.
    When -AsTable is set, writes to console and returns nothing.
.EXAMPLE
    $status = Get-OrchestratorStatus
    Get-OrchestratorStatus -AsTable
#>
function Get-OrchestratorStatus {
    [CmdletBinding()]
    [OutputType([void])]
    param([switch]$AsTable)

    $counts = Get-TaskCounts
    $fleet = Get-AgentFleetStatus
    $RepoDir = $script:RepoRoot

    $runningProcesses = @()
    if ($script:activeStreams) {
        foreach ($ns in $script:activeStreams.Keys) {
            $s = $script:activeStreams[$ns]
            $elapsed = if ($s.StartTime) { [math]::Round(((Get-Date) - $s.StartTime).TotalMinutes, 1) } else { $null }
            $runningProcesses += [PSCustomObject]@{
                Namespace  = $ns
                StreamId   = $s.Id
                Role       = $s.Role
                StartTime  = if ($s.StartTime) { $s.StartTime.ToString('o') } else { $null }
                ElapsedMin = $elapsed
                Status     = $s.Status
            }
        }
    }

    if ($AsTable) {
        Write-Host "`n=== Orchestrator Status ===" -ForegroundColor Cyan
        Write-Host "Queue counts:" -ForegroundColor White
        Write-Host "  Code:     $($counts.RootCoder) (+ $($counts.LockedCoder) locked) = $($counts.CoderWorkload) workload" -ForegroundColor DarkGray
        Write-Host "  Review:   $($counts.Review) (+ $($counts.LockedReviewer) locked) = $($counts.ReviewerWorkload) workload" -ForegroundColor DarkGray
        Write-Host "  Handoff:  $($counts.Handoff) files" -ForegroundColor DarkGray
        Write-Host "  Working:  $($counts.Working) files across $($counts.ActiveStreams) streams" -ForegroundColor DarkGray
        Write-Host "  Failed:   $($counts.Failed) files" -ForegroundColor DarkGray
        Write-Host "  ToDo:     $($counts.ToDo) files" -ForegroundColor DarkGray
        Write-Host "  Manual:   $($counts.Manual) files" -ForegroundColor DarkGray
        Write-Host "  Paused:   $($counts.Paused) files" -ForegroundColor DarkGray
        Write-Host "  Complete: $($counts.CompleteFiles) files + $($counts.CompleteDirs) dirs" -ForegroundColor DarkGray
        if ($runningProcesses.Count -gt 0) {
            Write-Host "`nActive streams:" -ForegroundColor White
            foreach ($p in $runningProcesses) {
                $icon = if ($p.Status -eq "running") { "▶" } else { "●" }
                Write-Host "  $icon $($p.StreamId) ($($p.Role)) [$($p.Namespace)] — $($p.ElapsedMin)m" -ForegroundColor DarkGray
            }
        }
        if ($fleet) {
            $running = $fleet | Where-Object { $_.Status -eq "RUNNING" }
            if ($running) {
                Write-Host "`nFleet agents:" -ForegroundColor White
                foreach ($a in $running) {
                    Write-Host "  $($a.Role[0]) $($a.AgentId) (PID $($a.PID)) - $($a.Mode), $($a.Elapsed)" -ForegroundColor DarkGray
                }
            }
        }
        Write-Host ""
        return
    }

    return [PSCustomObject]@{
        Queues = [PSCustomObject]@{
            Code       = $counts.RootCoder
            Review     = $counts.Review
            Handoff    = $counts.Handoff
            Working    = $counts.Working
            Failed     = $counts.Failed
            ToDo       = $counts.ToDo
            Manual     = $counts.Manual
            Paused     = $counts.Paused
            CompleteFiles = $counts.CompleteFiles
            CompleteDirs  = $counts.CompleteDirs
            LockedCoder   = $counts.LockedCoder
            LockedReviewer = $counts.LockedReviewer
            CoderWorkload  = $counts.CoderWorkload
            ReviewerWorkload = $counts.ReviewerWorkload
        }
        ActiveStreams = $runningProcesses
        FleetAgents   = $fleet | Where-Object { $_.Status -eq "RUNNING" }
    }
}

Export-ModuleMember -Function Get-OrchestratorStatus
