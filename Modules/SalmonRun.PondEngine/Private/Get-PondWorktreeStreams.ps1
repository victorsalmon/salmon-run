function Get-PondWorktreeStreams {
    <#
    .SYNOPSIS
        Allocates one git worktree stream for each namespace that appears in the
        agentic queues.
    .DESCRIPTION
        Scans Code, Review, Audit and QA for .md plan files, groups them by
        namespace, resolves a target code repo for each namespace, and ensures a
        per-namespace worktree branch exists.  Existing worktrees are reused.
    .OUTPUTS
        PondStream[]
    #>
    [CmdletBinding()]
    [OutputType([PondStream[]])]
    param(
        [string]$TaskRoot = (Get-SalmonTaskRoot),

        [string]$RepoDir = (Get-SalmonRunRepoRoot),

        [string]$ConfigPath = (Join-Path (Get-SalmonHome) 'orchestrator.config.json')
    )

    function ConvertTo-GitSafeName {
        param([string]$Name)
        $safe = $Name -replace '[^a-zA-Z0-9_.@{}\/-]+', '-'
        $safe = $safe -replace '_{2,}', '_'
        $safe = $safe -replace '-{2,}', '-'
        $safe = $safe -replace '\.{2,}', '.'
        $safe = $safe.Trim('-.')
        if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'namespace' }
        return $safe
    }

    function Get-RepoWorktreeList {
        param([string]$RepoPath)
        $list = @()
        $raw = & git -C $RepoPath worktree list --porcelain 2>&1
        if ($LASTEXITCODE -ne 0) { return $list }
        $current = $null
        foreach ($line in ($raw -split '\r?\n')) {
            if ($line -match '^worktree (.+)') {
                if ($current) { $list += $current }
                $current = [PSCustomObject]@{ Path = $Matches[1].Trim(); Branch = ''; Head = '' }
            } elseif ($line -match '^HEAD (.+)') {
                if ($current) { $current.Head = $Matches[1].Trim() }
            } elseif ($line -match '^branch (.+)') {
                if ($current) { $current.Branch = $Matches[1].Trim() }
            } elseif ($line -eq '') {
                if ($current) { $list += $current; $current = $null }
            }
        }
        if ($current) { $list += $current }
        return $list
    }

    function Test-BranchExists {
        param([string]$RepoPath, [string]$Branch)
        $null = & git -C $RepoPath show-ref --verify --quiet "refs/heads/$Branch" 2>&1
        return ($LASTEXITCODE -eq 0)
    }

    $namespaceRepoMap = @{}
    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
        try {
            $cfg = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
            if ($cfg -and $cfg['namespaceRepoMap']) {
                $namespaceRepoMap = $cfg['namespaceRepoMap']
            }
        } catch {
            Write-Verbose "Get-PondWorktreeStreams: could not parse config $ConfigPath : $_"
        }
    }

    $planFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($queue in @('Code', 'Review', 'Audit', 'QA')) {
        $queuePath = Join-Path $TaskRoot $queue
        if (-not (Test-Path -LiteralPath $queuePath)) { continue }
        $planFiles.AddRange(@(Get-ChildItem -Path "$queuePath/*.md" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }))
    }

    if ($planFiles.Count -eq 0) { return @() }

    $streams = [System.Collections.ArrayList]::new()
    $grouped = $planFiles | Group-Object { Get-PondFileNamespace -FileName $_.Name }

    foreach ($grp in $grouped) {
        $ns = $grp.Name
        $firstFile = @($grp.Group | Sort-Object Name | Select-Object -First 1)

        $tempGroup = [PondGroup]::new()
        $tempGroup.Namespace = $ns
        $tempGroup.Files = $firstFile

        $tempContext = [PondContext]::new()
        $tempContext.RepoDir = $RepoDir
        $tempContext.Config = [PSCustomObject]@{ NamespaceRepoMap = $namespaceRepoMap }

        Resolve-PondGroupRepo -Group $tempGroup -Context $tempContext

        $baseRepo = $tempGroup.RepoPath

        # The resolver may fall back to the salmon-run repo.  Prefer an explicit
        # C:\Repos\<namespace> directory if one exists and is a git repo.
        if (-not (Test-Path -LiteralPath (Join-Path $baseRepo '.git'))) {
            $defaultRepo = Join-Path 'C:\Repos' $ns
            if (Test-Path -LiteralPath (Join-Path $defaultRepo '.git')) {
                $baseRepo = $defaultRepo
            } elseif (Test-Path -LiteralPath (Join-Path $RepoDir '.git')) {
                $baseRepo = $RepoDir
            } else {
                Write-Warning "Get-PondWorktreeStreams: no git repo found for namespace '$ns'; skipping"
                continue
            }
        }

        $sanitizedNs = ConvertTo-GitSafeName -Name $ns
        $branchName = "salmon-$sanitizedNs"

        $repoParent = Split-Path -Path $baseRepo -Parent
        $repoName = Split-Path -Path $baseRepo -Leaf
        $worktreePath = Join-Path $repoParent "$repoName-salmon-$sanitizedNs"

        $worktreeList = Get-RepoWorktreeList -RepoPath $baseRepo
        $existingByPath = $worktreeList | Where-Object { $_.Path -eq $worktreePath } | Select-Object -First 1
        $existingByBranch = $worktreeList | Where-Object { $_.Branch -eq "refs/heads/$branchName" } | Select-Object -First 1

        if ($existingByPath) {
            Write-Verbose "Get-PondWorktreeStreams: reusing worktree $worktreePath for $ns"
        } elseif ($existingByBranch) {
            # The branch is already checked out elsewhere; use the existing worktree.
            $worktreePath = $existingByBranch.Path
            Write-Verbose "Get-PondWorktreeStreams: branch $branchName already in worktree $worktreePath for $ns"
        } else {
            if (Test-Path -LiteralPath $worktreePath) {
                Write-Warning "Get-PondWorktreeStreams: path $worktreePath exists but is not a valid worktree for $ns; skipping"
                continue
            }

            $currentBranch = & git -C $baseRepo rev-parse --abbrev-ref HEAD 2>&1
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentBranch)) {
                $currentBranch = 'main'
            }

            $null = & git -C $baseRepo fetch origin $currentBranch 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Verbose "Get-PondWorktreeStreams: fetch for $baseRepo reported a non-zero exit; continuing"
            }

            # Only reset the main worktree if it is clean and not ahead of the
            # remote, so we do not discard uncommitted orchestrator state.
            $remoteBranch = "origin/$currentBranch"
            $null = & git -C $baseRepo show-ref --verify --quiet "refs/remotes/$remoteBranch" 2>&1
            $hasRemote = ($LASTEXITCODE -eq 0)
            $isDirty = $false
            $isAhead = $false
            if ($hasRemote) {
                $null = & git -C $baseRepo diff --quiet 2>&1
                $isDirty = $LASTEXITCODE -ne 0
                $null = & git -C $baseRepo diff --cached --quiet 2>&1
                $isDirty = $isDirty -or ($LASTEXITCODE -ne 0)
                $aheadOutput = & git -C $baseRepo rev-list --count "$remoteBranch..$currentBranch" 2>&1
                $aheadCount = 0
                if ($LASTEXITCODE -eq 0) {
                    $null = [int]::TryParse($aheadOutput, [ref]$aheadCount)
                }
                if ($aheadCount -gt 0) { $isAhead = $true }

                if (-not $isDirty -and -not $isAhead) {
                    $null = & git -C $baseRepo reset --hard $remoteBranch 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        Write-Verbose "Get-PondWorktreeStreams: reset of $baseRepo to $remoteBranch failed; continuing"
                    }
                }
            }

            $branchExists = Test-BranchExists -RepoPath $baseRepo -Branch $branchName
            if ($branchExists) {
                $null = & git -C $baseRepo worktree add $worktreePath $branchName 2>&1
            } else {
                $baseRef = if ($hasRemote) { $remoteBranch } else { $currentBranch }
                $null = & git -C $baseRepo worktree add -b $branchName $worktreePath $baseRef 2>&1
            }

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Get-PondWorktreeStreams: could not add worktree $worktreePath for $ns"
                continue
            }

            $worktreeList = Get-RepoWorktreeList -RepoPath $baseRepo
            $added = $worktreeList | Where-Object { $_.Path -eq $worktreePath } | Select-Object -First 1
            if (-not $added) {
                Write-Warning "Get-PondWorktreeStreams: worktree list does not contain $worktreePath for $ns after add"
                continue
            }
        }

        $stream = New-PondStream -Id $ns -Branch $branchName -Path $worktreePath -TaskRoot $TaskRoot -LaneIdPrefix "$sanitizedNs-"
        $null = $streams.Add($stream)
    }

    return $streams.ToArray()
}
