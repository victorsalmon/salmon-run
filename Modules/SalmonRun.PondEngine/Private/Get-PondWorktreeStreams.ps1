function ConvertTo-GitSafeName {
    param([string]$Name)
    $safe = $Name -replace '[^a-zA-Z0-9_.@{}/\-]+', '-'
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
            $current = [PSCustomObject]@{ Path = ($Matches[1].Trim() -replace '/', '\'); Branch = ''; Head = '' }
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

function New-PondWorktreeStream {
    <#
    .SYNOPSIS
        Builds a PondStream metadata object for a namespace/worktree without
        touching git.  The worktree path and branch are computed from the
        resolved base repo and the plan namespace.
    #>
    [CmdletBinding()]
    [OutputType([PondStream])]
    param(
        [Parameter(Mandatory)]
        [string]$Namespace,

        [Parameter(Mandatory)]
        [string]$RepoPath,

        [string]$TaskRoot = (Get-SalmonTaskRoot)
    )

    $sanitized = ConvertTo-GitSafeName -Name $Namespace
    $branchName = "salmon-$sanitized"

    $repoParent = Split-Path -Path $RepoPath -Parent
    $repoName = Split-Path -Path $RepoPath -Leaf
    $worktreePath = Join-Path $repoParent "$repoName-salmon-$sanitized"

    $stream = New-PondStream -Id $Namespace -Branch $branchName -Path $worktreePath -TaskRoot $TaskRoot -LaneIdPrefix "$sanitized-"
    $stream | Add-Member -NotePropertyName BaseRepo -NotePropertyValue $RepoPath -Force
    return $stream
}

function Initialize-PondWorktree {
    <#
    .SYNOPSIS
        Creates the git worktree/branch for a PondStream if it does not exist.
    .OUTPUTS
        bool.  $true if a usable worktree is available at $Stream.Path.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [PondStream]$Stream,

        [string]$BaseRepo = $Stream.BaseRepo
    )

    if ([string]::IsNullOrWhiteSpace($BaseRepo)) {
        Write-Warning "Initialize-PondWorktree: no base repo for stream '$($Stream.Id)'"
        return $false
    }

    $worktreePath = $Stream.Path
    $branchName = $Stream.Branch

    $worktreeList = Get-RepoWorktreeList -RepoPath $BaseRepo
    $existingByPath = $worktreeList | Where-Object { $_.Path -eq $worktreePath } | Select-Object -First 1
    $existingByBranch = $worktreeList | Where-Object { $_.Branch -eq "refs/heads/$branchName" } | Select-Object -First 1

    if ($existingByPath) {
        Write-Verbose "Initialize-PondWorktree: reusing worktree $worktreePath for $($Stream.Id)"
        return $true
    }

    if ($existingByBranch) {
        # The branch is already checked out elsewhere; point this stream at the existing worktree.
        $Stream.Path = $existingByBranch.Path
        Write-Verbose "Initialize-PondWorktree: branch $branchName already in worktree $($existingByBranch.Path) for $($Stream.Id)"
        return $true
    }

    if (Test-Path -LiteralPath $worktreePath) {
        Write-Warning "Initialize-PondWorktree: path $worktreePath exists but is not a valid worktree for $($Stream.Id); skipping"
        return $false
    }

    $currentBranch = & git -C $BaseRepo rev-parse --abbrev-ref HEAD 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentBranch)) {
        $currentBranch = 'main'
    }

    $null = & git -C $BaseRepo fetch origin $currentBranch 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Verbose "Initialize-PondWorktree: fetch for $BaseRepo reported a non-zero exit; continuing"
    }

    # Only reset the main worktree if it is clean and not ahead of the remote.
    $remoteBranch = "origin/$currentBranch"
    $null = & git -C $BaseRepo show-ref --verify --quiet "refs/remotes/$remoteBranch" 2>&1
    $hasRemote = ($LASTEXITCODE -eq 0)
    $isDirty = $false
    $isAhead = $false
    if ($hasRemote) {
        $null = & git -C $BaseRepo diff --quiet 2>&1
        $isDirty = $LASTEXITCODE -ne 0
        $null = & git -C $BaseRepo diff --cached --quiet 2>&1
        $isDirty = $isDirty -or ($LASTEXITCODE -ne 0)
        $aheadOutput = & git -C $BaseRepo rev-list --count "$remoteBranch..$currentBranch" 2>&1
        $aheadCount = 0
        if ($LASTEXITCODE -eq 0) {
            $null = [int]::TryParse($aheadOutput, [ref]$aheadCount)
        }
        if ($aheadCount -gt 0) { $isAhead = $true }

        if (-not $isDirty -and -not $isAhead) {
            $null = & git -C $BaseRepo reset --hard $remoteBranch 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Verbose "Initialize-PondWorktree: reset of $BaseRepo to $remoteBranch failed; continuing"
            }
        }
    }

    $branchExists = Test-BranchExists -RepoPath $BaseRepo -Branch $branchName
    if ($branchExists) {
        $null = & git -C $BaseRepo worktree add $worktreePath $branchName 2>&1
    } else {
        $baseRef = if ($hasRemote) { $remoteBranch } else { $currentBranch }
        $null = & git -C $BaseRepo worktree add -b $branchName $worktreePath $baseRef 2>&1
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Initialize-PondWorktree: could not add worktree $worktreePath for $($Stream.Id)"
        return $false
    }

    $worktreeList = Get-RepoWorktreeList -RepoPath $BaseRepo
    $added = $worktreeList | Where-Object { $_.Path -eq $worktreePath } | Select-Object -First 1
    if (-not $added) {
        Write-Warning "Initialize-PondWorktree: worktree list does not contain $worktreePath for $($Stream.Id) after add"
        return $false
    }

    return $true
}

function Get-PondWorktreeStreams {
    <#
    .SYNOPSIS
        Discovers one PondStream per queued namespace.
    .DESCRIPTION
        Scans Code, Review, Audit and QA for .md plan files, groups them by
        namespace, resolves a target code repo for each group, and returns a
        PondStream with computed (but not necessarily created) worktree metadata.
    .OUTPUTS
        PondStream[]
    #>
    [CmdletBinding()]
    [OutputType([PondStream[]])]
    param(
        [string]$TaskRoot = (Get-SalmonTaskRoot),

        [string]$RepoDir = (Get-SalmonRunRepoRoot),

        [string]$ConfigPath = (Join-Path (Get-SalmonHome) 'orchestrator.config.json'),

        [switch]$Create
    )

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

    # Streams are needed for every agentic pond, not just Code/Review/Audit/QA.
    # Intake, ProjectReview, and QA plans also need a target worktree stream
    # before Start-PondEngine can spawn a lane for them.
    $planFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($queue in @('Code', 'Review', 'Audit', 'QA', 'Intake', 'ProjectReview')) {
        $queuePath = Join-Path $TaskRoot $queue
        if (-not (Test-Path -LiteralPath $queuePath)) { continue }
        $files = @(Get-ChildItem -Path "$queuePath/*.md" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
        foreach ($f in $files) { $planFiles.Add($f) }
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

        # The resolver may fall back to the salmon-run repo. Public Salmon Run
        # must not guess a machine-specific fleet root; callers map namespaces
        # through orchestrator.config.json when target repos live elsewhere.
        if (-not (Test-Path -LiteralPath (Join-Path $baseRepo '.git'))) {
            if (Test-Path -LiteralPath (Join-Path $RepoDir '.git')) {
                $baseRepo = $RepoDir
            } else {
                Write-Warning "Get-PondWorktreeStreams: no git repo found for namespace '$ns'; skipping"
                continue
            }
        }

        $stream = New-PondWorktreeStream -Namespace $ns -RepoPath $baseRepo -TaskRoot $TaskRoot

        if ($Create) {
            $ready = Initialize-PondWorktree -Stream $stream -BaseRepo $baseRepo
            if (-not $ready) { continue }
        }

        $null = $streams.Add($stream)
    }

    return $streams.ToArray()
}
