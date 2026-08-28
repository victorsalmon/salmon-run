#Requires -Version 7.0

# PondEngine class definitions
# A Pond is a generalizable station in the salmon-run workflow. Each pond has
# a folder, a role, entry gates, operator limits, a task pipeline, and
# transitions on success/failure. Worktrees are modelled as PondStreams.

class PondTask {
    [string]$Name
    [string]$Type
    [string]$Function
    [hashtable]$Arguments
    [PondTask[]]$SubTasks
}

class PondEntryGate {
    [bool]$Enabled
    [bool]$SkipScheduled
    [bool]$SkipBlocked
    [bool]$DependencyReady
    [string]$EvidenceGate
    [string[]]$RequiredHeaders
    [string]$OnInvalid      # e.g. 'Failed', 'Paused', 'Manual', 'Intake' — where to park invalid plans
}

class PondOperators {
    [int]$ParallelCount        # concurrent operators for this pond per stream
    [int]$MinGuarantee         # minimum operators to reserve if work exists
    [int]$MaxNewPerIteration   # throttle new operators per loop pass
    [int]$MaxFilesPerGroup     # split large namespace groups into smaller chunks
}

class PondStream {
    [string]$Id                # stream identifier, e.g. 'stream-1'
    [string]$Branch            # git branch for this worktree stream
    [string]$Path              # worktree path on disk
    [hashtable]$Lanes          # role -> lane objects
    [bool]$Idle
}

class PondLane {
    [string]$Id
    [string]$Role
    [string]$StreamId
    [string]$Path
    [bool]$Idle
}

class PondTransition {
    [string]$MoveTo
    [int]$MaxRetries
    [string]$FinalMoveTo
}

class PondExecutionProfile {
    [string]$Tier
    [string]$Harness
    [string]$Provider
    [string]$Model
    [string]$Effort
    [string]$Cli
    [string]$ExecutorFile
    [int]$TimeoutMinutes
    [string[]]$Credentials
    [string]$CostRule
    [double]$ApiCostPer1KTokens
    [double]$EffectiveCostPer1KTokens

    # Benchmark-enriched fields (optional; loaded from ~/.salmon/benchmarks)
    [hashtable]$Benchmarks
    [double]$TokenizerEfficiency
    [double]$SpeedTokPerS
    [string]$ReasoningEffort
    [double]$ThinkingTokenRatio
    [double]$ThinkingTokensPer1KOutput
    [double]$CostWithThinking
    [hashtable]$ProviderPricing
    [string[]]$References
}

class Pond {
    [string]$Name
    [string]$Folder
    [string]$Role
    [PondOperators]$Operators
    [PondEntryGate]$Entry
    [string]$GroupBy
    [PondTask[]]$Tasks
    [PondTransition]$OnSuccess
    [PondTransition]$OnFailure
    [string]$Description
    [string]$DefaultBranch     # branch this pond uses when not in a multi-stream setup
}

class PondGroup {
    [string]$Namespace
    [string]$Role
    [string]$Module
    [System.IO.FileInfo[]]$Files
    [string]$LaneId
    [string]$StreamPath
    [PondStream]$Stream
    [string]$RepoPath     # target code repository for the plans in this group
}

class PondContext {
    [string]$RepoDir
    [hashtable]$ActiveStreams
    [hashtable]$UsedNamespaces
    [hashtable]$BusyNamespaces
    [System.Collections.ArrayList]$Streams
    [System.Collections.Generic.List[datetime]]$CrashHistory
    [int]$Iteration
    [PSCustomObject]$Counts
    [Pond]$CurrentPond
    [PondGroup]$CurrentGroup
    [PSCustomObject]$Config
    [bool]$Continue
    [bool]$Success
    [string]$TaskRoot
}
