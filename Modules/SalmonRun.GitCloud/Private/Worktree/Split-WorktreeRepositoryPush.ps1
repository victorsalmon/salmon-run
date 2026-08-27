function Split-WorktreeRepositoryPush {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RemoteUrl,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [int]$SplitThreshold
    )

    $head = git rev-parse HEAD 2>$null
    $root = git rev-list --max-parents=0 HEAD 2>$null | Select-Object -First 1
    if (-not $head -or -not $root) {
        throw "Split-WorktreeRepositoryPush: could not determine commit range."
    }

    $commits = git rev-list --reverse "$root..$head" 2>$null
    if (-not $commits) {
        return Invoke-WorktreeGitPush -RemoteUrl $RemoteUrl -Branch $Branch -Token $Token
    }

    $batchSize = [Math]::Max(1, $SplitThreshold)
    $results = @()
    $batch = @()
    foreach ($commit in $commits) {
        $batch += $commit
        if ($batch.Count -ge $batchSize) {
            $results += Push-WorktreeCommitBatch -Batch $batch -RemoteUrl $RemoteUrl -Branch $Branch -Token $Token
            $batch = @()
        }
    }
    if ($batch.Count -gt 0) {
        $results += Push-WorktreeCommitBatch -Batch $batch -RemoteUrl $RemoteUrl -Branch $Branch -Token $Token
    }

    $failed = $results | Where-Object { -not $_.Success }
    return [pscustomobject]@{
        Success  = ($failed.Count -eq 0)
        Batched  = $true
        Batches  = $results.Count
        Failed   = $failed.Count
        Remote   = $RemoteUrl
        Branch   = $Branch
    }
}

function Push-WorktreeCommitBatch {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Batch,

        [Parameter(Mandatory)]
        [string]$RemoteUrl,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$Token
    )

    $last = $Batch[-1]
    $result = Invoke-SalmonRunGitCloudPush -RemoteUrl $RemoteUrl -RefSpec "$($last):refs/heads/$Branch" -Token $Token
    return [pscustomobject]@{
        Success  = $result.Success
        ExitCode = $result.ExitCode
        Commit   = $last.Substring(0, [Math]::Min(7, $last.Length))
        Branch   = $Branch
    }
}
