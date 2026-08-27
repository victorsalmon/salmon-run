<#
.SYNOPSIS
    Merges all agent branches back to main in connascence order with conflict handling.
.DESCRIPTION
    Processes an ordered list of branch names, merging each back to main
    with --no-ff to preserve branch topology. On conflict, writes a
    merge-plan file to Tasks/Merge/ and continues to the next branch.
    Configures the union merge driver for .md and .Tests.ps1 files
    to reduce false conflict escalations.
.PARAMETER Branches
    Ordered list of branch names to merge (pre-sorted by connascence).
.PARAMETER RepoRoot
    Root of the git repository. Defaults to the current directory.
.EXAMPLE
    Merge-AgentBranches -Branches @('wt/coder-a', 'wt/coder-b', 'wt/coder-c')
.EXAMPLE
    Merge-AgentBranches -Branches $branches -RepoRoot C:\repo
#>
function Merge-AgentBranches {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateCount(1, [int]::MaxValue)]
        [string[]]$Branches,

        [string]$RepoRoot = (Get-Location).Path
    )

    $ErrorActionPreference = "Stop"
    pushd $RepoRoot
    try {
        # Ensure union merge driver is configured
        $existingDriver = git config --local merge.union.driver 2>$null
        if (-not $existingDriver) {
            Write-Host "[MERGE] Configuring union merge driver..." -ForegroundColor Cyan
            git config --local merge.union.driver true 2>&1 | Out-Null
        }

        $merged = 0
        $conflicts = 0
        $conflictBranches = @()
        $stashedTaskFiles = $false

        # Preserve in-flight dispatch state (Tasks/Code + Tasks/Working) so that
        # git checkout / pull / merge operations on main do not restore the
        # tracked plan copies from HEAD and wipe lane lock headers.
        $taskDirs = @('Tasks/Code', 'Tasks/Working')
        $taskDirty = $null -ne (git status --porcelain -- $taskDirs 2>$null | Where-Object { $_ })
        if ($taskDirty) {
            Write-Host "[MERGE] Stashing in-flight task state: $($taskDirs -join ', ')" -ForegroundColor Cyan
            git stash push --include-untracked -m "orchestrator-merge: preserve in-flight task state" -- $taskDirs 2>&1 | ForEach-Object { Write-Host "    $_" }
            if ($LASTEXITCODE -eq 0) { $stashedTaskFiles = $true } else { Write-Host "  ⚠ Failed to stash task state" -ForegroundColor Red }
        }

        foreach ($branch in $Branches) {
            Write-Host "[MERGE] Processing branch: $branch" -ForegroundColor Cyan

            # Step 1: Rebase the branch onto latest main before merge (prevents conflicts from a stale branch base)
            $rebaseOk = $true
            if ($branch -match '^wt/module-\d+$') {
                $wtPath = Join-Path $RepoRoot "Tasks/Worktrees" ($branch -replace '^wt/')
                if (Test-Path $wtPath) {
                    Write-Host "  → Rebasing worktree $branch" -ForegroundColor DarkGray
                    git -C $wtPath pull --rebase origin main 2>&1 | ForEach-Object { Write-Host "    $_" }
                    if ($LASTEXITCODE -ne 0) { $rebaseOk = $false; Write-Host "  ✗ Rebase failed for $branch (exit $LASTEXITCODE)" -ForegroundColor Red }
                }
            } elseif ($branch -match '^wt/') {
                Write-Host "  → Rebasing branch $branch" -ForegroundColor DarkGray
                git -C $RepoRoot checkout $branch 2>&1 | ForEach-Object { Write-Host "    $_" }
                if ($LASTEXITCODE -eq 0) {
                    git -C $RepoRoot pull --rebase origin main 2>&1 | ForEach-Object { Write-Host "    $_" }
                    if ($LASTEXITCODE -ne 0) { $rebaseOk = $false; Write-Host "  ✗ Rebase failed for $branch (exit $LASTEXITCODE)" -ForegroundColor Red }
                    git -C $RepoRoot checkout main 2>&1 | ForEach-Object { Write-Host "    $_" }
                } else {
                    $rebaseOk = $false; Write-Host "  ✗ Failed to checkout $branch" -ForegroundColor Red
                }
            }
            if (-not $rebaseOk) { $conflicts++; $conflictBranches += $branch; continue }

            # Step 2: Checkout main and pull latest
            Write-Host "  → Checking out main..." -ForegroundColor DarkGray
            git checkout main 2>&1 | ForEach-Object { Write-Host "    $_" }
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ✗ Failed to checkout main (exit $LASTEXITCODE)" -ForegroundColor Red
                continue
            }

            Write-Host "  → Pulling latest origin/main..." -ForegroundColor DarkGray
            # Use WIP-commit-safe pull (same pattern as Invoke-GitPullSafe.ps1)
            # to avoid failure when the working tree has unstaged changes.
            $dirtyBefore = (git diff --name-only 2>$null).Count -gt 0 -or (git diff --cached --name-only 2>$null).Count -gt 0
            if ($dirtyBefore) {
                git add -A 2>&1 | Out-Null
                git commit -m "WIP: merge-phase-checkpoint" --no-verify 2>&1 | Out-Null
            }
            git pull --rebase origin main 2>&1 | ForEach-Object { Write-Host "    $_" }
            $pullExit = $LASTEXITCODE
            if ($dirtyBefore) {
                git reset --soft HEAD~1 2>&1 | Out-Null
                git reset 2>&1 | Out-Null
            }
            if ($pullExit -ne 0) {
                Write-Host "  ✗ Failed to pull origin/main (exit $pullExit)" -ForegroundColor Red
                continue
            }

            # Step 2: Merge with --no-ff
            $mergeMsg = "merge: $branch"
            Write-Host "  → Merging $branch into main..." -ForegroundColor DarkGray
            $mergeOutput = git merge --no-ff $branch -m $mergeMsg 2>&1
            $mergeExit = $LASTEXITCODE

            if ($mergeExit -eq 0) {
                # Step 3: Push on success
                Write-Host "  ✓ Merge successful, pushing..." -ForegroundColor Green
                git push origin main 2>&1 | ForEach-Object { Write-Host "    $_" }
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✓ $branch merged and pushed" -ForegroundColor Green
                    $merged++
                } else {
                    Write-Host "  ✗ Merge succeeded but push failed (exit $LASTEXITCODE)" -ForegroundColor Yellow
                }
            } else {
                # Step 4: Conflict — capture files, then abort and write merge-plan
                Write-Host "  ✗ Merge conflict detected for $branch" -ForegroundColor Red
                $conflictFiles = git diff --name-only --diff-filter=U 2>$null   # capture FIRST
                git merge --abort 2>&1 | Out-Null                               # then abort

                $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $mergePlanPath = "Tasks/Merge/$branch-conflict-$timestamp.md"
                $mergeDir = Split-Path -Parent $mergePlanPath

                if (-not (Test-Path -LiteralPath $mergeDir)) {
                    New-Item -ItemType Directory -Path $mergeDir -Force | Out-Null
                }

                $conflictList = if ($conflictFiles) { $conflictFiles -join "`n" } else { "(unable to list conflicted files)" }

                $planContent = @"
# Merge Conflict: $branch
**Date**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
**Source**: Merge-AgentBranches (Invoke-WorktreeMergeAll.ps1)
**Status**: unresolved

## Conflict Details
- **Branch**: $branch
- **Command**: `git merge --no-ff $branch -m "$mergeMsg"`
- **Merge output**:
```
$mergeOutput
```

## Conflicted Files
```
$conflictList
```

## Resolution
1. Checkout the branch: `git checkout $branch`
2. Pull latest main: `git pull --rebase origin main`
3. Resolve conflicts in the listed files
4. Commit the merge: `git commit -m "merge: resolve $branch conflicts"`
5. Push: `git push origin $branch`
6. Re-run Merge-AgentBranches (this branch will be skipped if already merged)

## Worktree
The worktree for this branch has been preserved at its original location.
"@

                $planContent | Out-File -FilePath $mergePlanPath -Encoding utf8
                Write-Host "  → Merge-plan written to $mergePlanPath" -ForegroundColor Yellow
                $conflicts++
                $conflictBranches += $branch
            }
        }

        $summary = [PSCustomObject]@{
            Merged           = $merged
            Conflicts        = $conflicts
            ConflictBranches = $conflictBranches
        }

        Write-Host "[MERGE] Complete: $merged merged, $conflicts conflict(s)" -ForegroundColor $(if ($conflicts -eq 0) { 'Green' } else { 'Yellow' })
        return $summary
    } finally {
        popd
        if ($stashedTaskFiles) {
            Write-Host "[MERGE] Restoring in-flight task state" -ForegroundColor Cyan
            git -C $RepoRoot stash pop 2>&1 | ForEach-Object { Write-Host "    $_" }
        }
    }
}

# NOTE: No Export-ModuleMember — this .ps1 is dot-sourced, not imported as a module.
