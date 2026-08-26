#Requires -Version 7.0

# PondEngine class definitions
# A Pond is a generalizable station in the salmon-run workflow. Each pond has
# a folder, a role, entry gates, capacity limits, a task pipeline, and
# transitions on success/failure.

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
}

class PondCapacity {
    [int]$ParallelCount
    [int]$MinGuarantee
    [int]$MaxNewPerIteration
}

class PondTransition {
    [string]$MoveTo
    [int]$MaxRetries
    [string]$FinalMoveTo
}

class Pond {
    [string]$Name
    [string]$Folder
    [string]$Role
    [PondCapacity]$Capacity
    [PondEntryGate]$Entry
    [string]$GroupBy
    [PondTask[]]$Tasks
    [PondTransition]$OnSuccess
    [PondTransition]$OnFailure
    [string]$Description
}

class PondGroup {
    [string]$Namespace
    [string]$Role
    [string]$Module
    [System.IO.FileInfo[]]$Files
    [string]$LaneId
    [string]$StreamPath
}

class PondContext {
    [string]$RepoDir
    [hashtable]$ActiveStreams
    [hashtable]$UsedNamespaces
    [hashtable]$BusyNamespaces
    [System.Collections.ArrayList]$PersistentLanes
    [System.Collections.Generic.List[datetime]]$CrashHistory
    [int]$Iteration
    [PSCustomObject]$Counts
    [Pond]$CurrentPond
    [PondGroup]$CurrentGroup
    [PSCustomObject]$Config
}
