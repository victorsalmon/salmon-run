function Push-PondRepos {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondContext]$Context,
        [Parameter(Mandatory)]
        [string]$FinalDest,
        [Parameter(Mandatory)]
        [string[]]$SourcePaths,
        [Parameter(Mandatory)]
        [System.IO.FileInfo[]]$DestFiles,
        [Parameter(Mandatory)]
        [string]$CommitMessage,

        [Parameter()]
        [switch]$TaskRepoOnly
    )

    $ErrorActionPreference = 'Continue'

    # Internal helper to push a single repo and record PondLog events.
    function Push-RepoWithLog {
        param(
            [string]$RepoPath,
            [string]$CommitMessage,
            [string]$RepoLabel
        )

        if (-not (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
            return
        }

        # Stage deletions of source files.
        foreach ($src in $SourcePaths) {
            if (Test-Path -LiteralPath $src) { continue }  # only deleted files
            $null = & git -C $RepoPath add -u -- $src 2>&1
        }

        # Stage destination files and any edits.
        foreach ($dst in $DestFiles) {
            if (Test-Path -LiteralPath $dst.FullName) {
                $null = & git -C $RepoPath add -- $dst.FullName 2>&1
            }
        }

        $status = & git -C $RepoPath status --porcelain 2>&1
        if (-not $status) { return }

        $null = & git -C $RepoPath commit -m "$CommitMessage" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "POND_COMMIT_FAILED repo=$RepoLabel message='$CommitMessage'"
            return
        }

        $sha = (& git -C $RepoPath log -1 --format=%H 2>&1) -as [string]
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) {
            Write-Warning "POND_COMMIT_SHA_FAILED repo=$RepoLabel"
            return
        }

        $null = & git -C $RepoPath pull --rebase --autostash 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "POND_PULL_REBASE_FAILED repo=$RepoLabel sha=$sha"
            return
        }

        $null = & git -C $RepoPath push 2>&1
        $pushed = ($LASTEXITCODE -eq 0)

        foreach ($dst in $DestFiles) {
            if (-not (Test-Path -LiteralPath $dst.FullName)) { continue }
            $now = Get-Date -Format 'o'
            $null = Add-PlanPondLog -PlanPath $dst.FullName -Entry @{
                ts     = $now
                pond   = $Pond.Name
                role   = $Pond.Role
                action = 'commit'
                detail = "$RepoLabel`: $CommitMessage @ $sha"
                agent  = 'PondEngine'
            } -ErrorAction SilentlyContinue
            if ($pushed) {
                $null = Add-PlanPondLog -PlanPath $dst.FullName -Entry @{
                    ts     = $now
                    pond   = $Pond.Name
                    role   = $Pond.Role
                    action = 'push'
                    detail = "$RepoLabel`: pushed to origin"
                    agent  = 'PondEngine'
                } -ErrorAction SilentlyContinue
            }
        }
    }

    # 1. Commit and push the .salmon task repo.
    # The queue root (TaskRoot) is Tasks/ under the .salmon home; the git repo is the parent.
    $taskRepo = Split-Path -Path $Context.TaskRoot -Parent
    if (-not (Test-Path -LiteralPath (Join-Path $taskRepo '.git'))) {
        $taskRepo = $Context.TaskRoot
    }
    Push-RepoWithLog -RepoPath $taskRepo -CommitMessage $CommitMessage -RepoLabel 'salmon-run-tasks'

    # 2. Commit and push the target code repo (unless this is a claim-only task repo commit).
    if (-not $TaskRepoOnly) {
        $codeRepo = if ($Context.CurrentGroup -and $Context.CurrentGroup.Stream -and $Context.CurrentGroup.Stream.Path) {
            $Context.CurrentGroup.Stream.Path
        } else {
            $Context.RepoDir
        }

        # For the target repo, stage all uncommitted changes from the agent.
        if (Test-Path -LiteralPath (Join-Path $codeRepo '.git')) {
            $null = & git -C $codeRepo add -u 2>&1
            $untracked = & git -C $codeRepo ls-files --others --exclude-standard 2>&1
            if ($untracked) {
                $untrackedPaths = $untracked -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                if ($untrackedPaths) {
                    $null = & git -C $codeRepo add -- $untrackedPaths 2>&1
                }
            }

            $repoCommitMsg = "$($Pond.Name): apply plan changes ($($DestFiles[0].Name))"
            Push-RepoWithLog -RepoPath $codeRepo -CommitMessage $repoCommitMsg -RepoLabel 'target-repo'
        }
    }

    $ErrorActionPreference = 'Stop'
}
