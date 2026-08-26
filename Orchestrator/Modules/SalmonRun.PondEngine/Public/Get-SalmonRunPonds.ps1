#Requires -Version 7.0

<#
.SYNOPSIS
    Returns the default salmon-run pond configuration.
.DESCRIPTION
    Each pond defines a folder, role, capacity, entry gate, grouping,
    task pipeline, and success/failure transitions. This is the canonical
    layout for the default vibecoding dev-ops pipeline.
#>
function Get-SalmonRunPonds {
    [CmdletBinding()]
    [OutputType([Pond[]])]
    param()

    $ponds = @()

    # Helper for new ponds
    function New-Pond {
        param(
            [string]$Name,
            [string]$Folder,
            [string]$Role,
            [string]$Description = '',
            [int]$ParallelCount = 1,
            [int]$MinGuarantee = 1,
            [int]$MaxNewPerIteration = 1,
            [switch]$Enabled,
            [switch]$SkipScheduled,
            [switch]$SkipBlocked,
            [switch]$DependencyReady,
            [string]$EvidenceGate = '',
            [string]$GroupBy = 'Namespace',
            [PondTask[]]$Tasks,
            [string]$OnSuccess = '',
            [int]$MaxRetries = 3,
            [string]$OnFailure = 'Failed'
        )
        $p = [Pond]::new()
        $p.Name = $Name
        $p.Folder = $Folder
        $p.Role = $Role
        $p.Description = $Description
        $p.Capacity = [PondCapacity]::new()
        $p.Capacity.ParallelCount = $ParallelCount
        $p.Capacity.MinGuarantee = $MinGuarantee
        $p.Capacity.MaxNewPerIteration = $MaxNewPerIteration
        $p.Entry = [PondEntryGate]::new()
        $p.Entry.Enabled = if ($PSBoundParameters.ContainsKey('Enabled')) { $Enabled.IsPresent } else { $true }
        $p.Entry.SkipScheduled = if ($PSBoundParameters.ContainsKey('SkipScheduled')) { $SkipScheduled.IsPresent } else { $true }
        $p.Entry.SkipBlocked = if ($PSBoundParameters.ContainsKey('SkipBlocked')) { $SkipBlocked.IsPresent } else { $true }
        $p.Entry.DependencyReady = $DependencyReady.IsPresent
        $p.Entry.EvidenceGate = $EvidenceGate
        $p.GroupBy = $GroupBy
        $p.Tasks = $Tasks
        $p.OnSuccess = [PondTransition]::new()
        $p.OnSuccess.MoveTo = $OnSuccess
        $p.OnSuccess.MaxRetries = $MaxRetries
        $p.OnSuccess.FinalMoveTo = $OnFailure
        $p.OnFailure = [PondTransition]::new()
        $p.OnFailure.MoveTo = $OnFailure
        $p.OnFailure.MaxRetries = $MaxRetries
        $p.OnFailure.FinalMoveTo = $OnFailure
        return $p
    }

    # Standard agentic task pipeline used by Coder, Reviewer, Planner, Auditor, QA
    $agentPipeline = @(
        [PondTask]@{ Name = 'Claim'; Type = 'Group'; Function = 'Invoke-PondTaskClaim' }
        [PondTask]@{ Name = 'Prepare'; Type = 'PerFile'; Function = 'Invoke-PondTaskPrepare' }
        [PondTask]@{ Name = 'ModelRoute'; Type = 'Group'; Function = 'Invoke-PondTaskModelRoute' }
        [PondTask]@{ Name = 'Spawn'; Type = 'Agent'; Function = 'Invoke-PondTaskSpawnAgent'; Arguments = @{ Command = 'work-{role}-once' } }
        [PondTask]@{ Name = 'Monitor'; Type = 'Poll'; Function = 'Invoke-PondTaskMonitorStream' }
        [PondTask]@{ Name = 'Transition'; Type = 'Group'; Function = 'Invoke-PondTaskTransition' }
    )

    $ponds += New-Pond -Name 'Intake' -Folder 'Tasks/Intake' -Role 'planner' -Description 'Interactive intake and feature discovery' -ParallelCount 2 -GroupBy 'Namespace' -Tasks @(
        [PondTask]@{ Name = 'Claim'; Type = 'Group'; Function = 'Invoke-PondTaskClaim' }
        [PondTask]@{ Name = 'ModelRoute'; Type = 'Group'; Function = 'Invoke-PondTaskModelRoute' }
        [PondTask]@{ Name = 'Spawn'; Type = 'Agent'; Function = 'Invoke-PondTaskSpawnAgent'; Arguments = @{ Command = 'work-planner-once' } }
        [PondTask]@{ Name = 'Monitor'; Type = 'Poll'; Function = 'Invoke-PondTaskMonitorStream' }
        [PondTask]@{ Name = 'Transition'; Type = 'Group'; Function = 'Invoke-PondTaskTransition' }
    ) -OnSuccess 'Code'

    $ponds += New-Pond -Name 'Code' -Folder 'Tasks/Code' -Role 'coder' -Description 'Implementation of ready plans' -ParallelCount 10 -MinGuarantee 1 -MaxNewPerIteration 7 -DependencyReady -EvidenceGate 'ready' -GroupBy 'Namespace' -Tasks $agentPipeline -OnSuccess 'Review' -OnFailure 'Code'

    $ponds += New-Pond -Name 'Review' -Folder 'Tasks/Review' -Role 'reviewer' -Description 'Verify coder output against plan' -ParallelCount 6 -MinGuarantee 1 -MaxNewPerIteration 5 -EvidenceGate 'implemented' -GroupBy 'Namespace' -Tasks $agentPipeline -OnSuccess 'Audit' -OnFailure 'Code'

    $ponds += New-Pond -Name 'Audit' -Folder 'Tasks/Audit' -Role 'auditor' -Description 'Best-practice, safety, and code-smell review' -ParallelCount 3 -MaxNewPerIteration 2 -GroupBy 'Namespace' -Tasks @(
        [PondTask]@{ Name = 'Claim'; Type = 'Group'; Function = 'Invoke-PondTaskClaim' }
        [PondTask]@{ Name = 'Prepare'; Type = 'PerFile'; Function = 'Invoke-PondTaskPrepare' }
        [PondTask]@{ Name = 'ModelRoute'; Type = 'Group'; Function = 'Invoke-PondTaskModelRoute' }
        [PondTask]@{ Name = 'Spawn'; Type = 'Agent'; Function = 'Invoke-PondTaskSpawnAgent'; Arguments = @{ Command = 'work-auditor-once' } }
        [PondTask]@{ Name = 'Monitor'; Type = 'Poll'; Function = 'Invoke-PondTaskMonitorStream' }
        [PondTask]@{ Name = 'Transition'; Type = 'Group'; Function = 'Invoke-PondTaskTransition' }
    ) -OnSuccess 'QA'

    $ponds += New-Pond -Name 'QA' -Folder 'Tasks/QA' -Role 'qa' -Description 'Property and mutation test maturation' -ParallelCount 3 -MaxNewPerIteration 2 -GroupBy 'Namespace' -Tasks @(
        [PondTask]@{ Name = 'Claim'; Type = 'Group'; Function = 'Invoke-PondTaskClaim' }
        [PondTask]@{ Name = 'Prepare'; Type = 'PerFile'; Function = 'Invoke-PondTaskPrepare' }
        [PondTask]@{ Name = 'ModelRoute'; Type = 'Group'; Function = 'Invoke-PondTaskModelRoute' }
        [PondTask]@{ Name = 'Spawn'; Type = 'Agent'; Function = 'Invoke-PondTaskSpawnAgent'; Arguments = @{ Command = 'work-qa-once' } }
        [PondTask]@{ Name = 'Monitor'; Type = 'Poll'; Function = 'Invoke-PondTaskMonitorStream' }
        [PondTask]@{ Name = 'Transition'; Type = 'Group'; Function = 'Invoke-PondTaskTransition' }
    ) -OnSuccess 'Complete'

    $ponds += New-Pond -Name 'Project' -Folder 'Tasks/Project' -Role 'project-planner' -Description 'Large feature plans split into child Code plans and a review plan' -ParallelCount 2 -MaxNewPerIteration 1 -GroupBy 'Namespace' -Tasks @(
        [PondTask]@{ Name = 'Claim'; Type = 'Group'; Function = 'Invoke-PondTaskClaim' }
        [PondTask]@{ Name = 'ModelRoute'; Type = 'Group'; Function = 'Invoke-PondTaskModelRoute' }
        [PondTask]@{ Name = 'Spawn'; Type = 'Agent'; Function = 'Invoke-PondTaskSpawnAgent'; Arguments = @{ Command = 'work-project-planner-once' } }
        [PondTask]@{ Name = 'Monitor'; Type = 'Poll'; Function = 'Invoke-PondTaskMonitorStream' }
        [PondTask]@{ Name = 'Transition'; Type = 'Group'; Function = 'Invoke-PondTaskTransition' }
    ) -OnSuccess 'ProjectReview'

    $ponds += New-Pond -Name 'ProjectReview' -Folder 'Tasks/ProjectReview' -Role 'project-reviewer' -Description 'Evaluate all child plans of a completed project' -ParallelCount 1 -MaxNewPerIteration 1 -EvidenceGate 'children-complete' -GroupBy 'Namespace' -Tasks @(
        [PondTask]@{ Name = 'Claim'; Type = 'Group'; Function = 'Invoke-PondTaskClaim' }
        [PondTask]@{ Name = 'Prepare'; Type = 'PerFile'; Function = 'Invoke-PondTaskPrepare' }
        [PondTask]@{ Name = 'ModelRoute'; Type = 'Group'; Function = 'Invoke-PondTaskModelRoute' }
        [PondTask]@{ Name = 'Spawn'; Type = 'Agent'; Function = 'Invoke-PondTaskSpawnAgent'; Arguments = @{ Command = 'work-project-reviewer-once' } }
        [PondTask]@{ Name = 'Monitor'; Type = 'Poll'; Function = 'Invoke-PondTaskMonitorStream' }
        [PondTask]@{ Name = 'Transition'; Type = 'Group'; Function = 'Invoke-PondTaskTransition' }
    ) -OnSuccess 'Complete'

    $ponds += New-Pond -Name 'Complete' -Folder 'Tasks/Complete' -Role 'archiver' -Description 'Compress and archive plans older than 7 days' -ParallelCount 1 -MaxNewPerIteration 1 -GroupBy 'None' -Tasks @(
        [PondTask]@{ Name = 'Archive'; Type = 'Local'; Function = 'Invoke-PondTaskArchive'; Arguments = @{ AgeDays = 7; ArchiveFormat = '7z' } }
    ) -OnSuccess 'Archive'

    return $ponds
}
