<#
.SYNOPSIS
    Mutation analysis for SalmonRun.GitCloud.

.DESCRIPTION
    Copies the Modules tree to a temp location, applies each curated source
    mutant, runs the GitCloud mutation-test oracle (Tests/SalmonRun.GitCloud
    .Mutation.Tests.ps1) against the mutated module, and reports how many
    mutants are "killed" (caught) by the tests. The mutation score is
    killed / total.

    Equivalent mutants (behavior-preserving) are reported but excluded from the
    denominator via the Equivalent list.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
    [string]$MutationTest = 'Tests/SalmonRun.GitCloud.Mutation.Tests.ps1',
    [string]$PesterVersion = '6.0.0'
)

$ErrorActionPreference = 'Stop'
$modulesSrc = Join-Path $RepoRoot 'Modules'
$mutationTestPath = Join-Path $RepoRoot $MutationTest

if (-not (Test-Path $modulesSrc)) { throw "Modules dir not found: $modulesSrc" }
if (-not (Test-Path $mutationTestPath)) { throw "Mutation test not found: $mutationTestPath" }

# Curated mutants: each targets a specific, unique source line in an in-scope file.
$mutants = @(
    @{
        Id = 'RemoteUrl-GitHubHost'; File = 'SalmonRun.GitCloud/Public/Core/Get-SalmonRunGitCloudRemoteUrl.ps1'
        From = '"https://github.com/$Owner/$Repo.git"'
        To   = '"https://github.co/$Owner/$Repo.git"'
    },
    @{
        Id = 'RemoteUrl-WorktreeHostSwap'; File = 'SalmonRun.GitCloud/Public/Core/Get-SalmonRunGitCloudRemoteUrl.ps1'
        From = '$hostName = if ($WorktreeHost) { $WorktreeHost } else { Get-WorktreeHost }'
        To   = '$hostName = if ($WorktreeHost) { Get-WorktreeHost } else { $WorktreeHost }'
    },
    @{
        Id = 'RemoteUrl-UnknownNoThrow'; File = 'SalmonRun.GitCloud/Public/Core/Get-SalmonRunGitCloudRemoteUrl.ps1'
        From = 'default    { throw "Unknown GitCloud provider: $Provider" }'
        To   = 'default    { return '' }'
    },
    @{
        Id = 'RemoteUrl-DropGitSuffix'; File = 'SalmonRun.GitCloud/Public/Core/Get-SalmonRunGitCloudRemoteUrl.ps1'
        From = 'return "$hostName/$Owner/$Repo.git"'
        To   = 'return "$hostName/$Owner/$Repo"'
    },
    @{
        Id = 'WorktreeHost-DefaultChanged'; File = 'SalmonRun.GitCloud/Private/Worktree/Get-WorktreeHost.ps1'
        From = "return 'https://worktree.example'"
        To   = "return 'https://worktree.example.com'"
    },
    @{
        Id = 'WorktreeHost-EnvPrecedenceDisabled'; File = 'SalmonRun.GitCloud/Private/Worktree/Get-WorktreeHost.ps1'
        From = 'if (-not [string]::IsNullOrWhiteSpace($env:WORKTREE_HOST)) {'
        To   = 'if ($false) {'
    },
    @{
        Id = 'Select-PushMapping'; File = 'SalmonRun.GitCloud/Public/Core/Select-SalmonRunGitCloudToken.ps1'
        From = "'push'   { 'PUSH' }"
        To   = "'push'   { 'WRITE' }"
    },
    @{
        Id = 'Select-WriteMapping'; File = 'SalmonRun.GitCloud/Public/Core/Select-SalmonRunGitCloudToken.ps1'
        From = "'write'  { 'WRITE' }"
        To   = "'write'  { 'READ' }"
    },
    @{
        Id = 'GitCloudToken-TypedEnvName'; File = 'SalmonRun.GitCloud/Public/Core/Get-SalmonRunGitCloudToken.ps1'
        From = '$EnvVarName = "SALMON_RUN_GITCLOUD_TOKEN_$($TokenType.ToUpper())"'
        To   = '$EnvVarName = "SALMON_RUN_GITCLOUD_TOKEN_X_$($TokenType.ToUpper())"'
    },
    @{
        Id = 'GitCloudToken-GenericFallbackName'; File = 'SalmonRun.GitCloud/Public/Core/Get-SalmonRunGitCloudToken.ps1'
        From = "GetEnvironmentVariable('SALMON_RUN_GITCLOUD_TOKEN')"
        To   = "GetEnvironmentVariable('SALMON_RUN_GITCLOUD_TOKEN_X')"
    },
    @{
        Id = 'GitHubToken-TypedEnvName'; File = 'SalmonRun.GitCloud/Public/GitHub/Get-GitHubToken.ps1'
        From = '$EnvVarName = "GITHUB_TOKEN_$($TokenType.ToUpper())"'
        To   = '$EnvVarName = "GITHUB_TOKEN_X_$($TokenType.ToUpper())"'
    },
    @{
        Id = 'GitHubToken-FinalFallbackName'; File = 'SalmonRun.GitCloud/Public/GitHub/Get-GitHubToken.ps1'
        From = "& `$credCmd -Name 'GITHUB_TOKEN'"
        To   = "& `$credCmd -Name 'GITHUB_TOKEN_X'"
    },
    @{
        Id = 'WorktreeToken-DefaultEnvName'; File = 'SalmonRun.GitCloud/Public/Worktree/Get-WorktreeToken.ps1'
        From = "[string]`$EnvVarName = 'WORKTREE_REPO_RW_ACCESS_TOKEN'"
        To   = "[string]`$EnvVarName = 'WORKTREE_REPO_RW_ACCESS_TOKEN_X'"
    },
    @{
        Id = 'PushGitHub-ProviderSwap'; File = 'SalmonRun.GitCloud/Public/GitHub/Push-GitHubRepository.ps1'
        From = 'Get-SalmonRunGitCloudRemoteUrl -Provider GitHub'
        To   = 'Get-SalmonRunGitCloudRemoteUrl -Provider Worktree'
    },
    @{
        Id = 'PushGitHub-RepoOwnerSwap'; File = 'SalmonRun.GitCloud/Public/GitHub/Push-GitHubRepository.ps1'
        From = '-Owner $Owner -Repo $Repo'
        To   = '-Owner $Owner -Repo $Owner'
    },
    @{
        Id = 'PushGitHub-RefSpecPrefix'; File = 'SalmonRun.GitCloud/Public/GitHub/Push-GitHubRepository.ps1'
        From = 'return Invoke-SalmonRunGitCloudPush -RemoteUrl $remoteUrl -RefSpec $pushBranch -Token $resolvedToken'
        To   = 'return Invoke-SalmonRunGitCloudPush -RemoteUrl $remoteUrl -RefSpec "x/$pushBranch" -Token $resolvedToken'
    },
    @{
        Id = 'PushWorktree-ProviderSwap'; File = 'SalmonRun.GitCloud/Public/Worktree/Push-WorktreeRepository.ps1'
        From = 'Get-SalmonRunGitCloudRemoteUrl -Provider Worktree'
        To   = 'Get-SalmonRunGitCloudRemoteUrl -Provider GitHub'
    },
    @{
        Id = 'PushWorktree-DropHostParam'; File = 'SalmonRun.GitCloud/Public/Worktree/Push-WorktreeRepository.ps1'
        From = '-Owner $Owner -Repo $Repo -WorktreeHost $WorktreeHost'
        To   = '-Owner $Owner -Repo $Repo'
    },
    @{
        Id = 'PushWorktree-BranchPrefix'; File = 'SalmonRun.GitCloud/Public/Worktree/Push-WorktreeRepository.ps1'
        From = 'return Invoke-WorktreeGitPush -RemoteUrl $remoteUrl -Branch $pushBranch -Token $resolvedToken'
        To   = 'return Invoke-WorktreeGitPush -RemoteUrl $remoteUrl -Branch "x/$pushBranch" -Token $resolvedToken'
    }
)

# Mutants that are behavior-preserving (unreachable given ValidateSet etc.) are
# flagged equivalent and excluded from the score denominator.
$equivalent = @()

function Invoke-Oracle {
    param([string]$ModuleRoot)
    $sep = [System.IO.Path]::PathSeparator
    $env:GITCLOUD_MUTATION_MODULE_ROOT = $ModuleRoot
    if ($env:PSModulePath -notlike "*$ModuleRoot*") {
        $env:PSModulePath = "$ModuleRoot$sep$env:PSModulePath"
    }
    try {
        Import-Module Pester -RequiredVersion $PesterVersion -ErrorAction Stop
        $r = Invoke-Pester -Path $mutationTestPath -Output None -PassThru -ErrorAction Stop
        return [pscustomobject]@{
            Failed = $r.FailedCount
            Error  = $null
        }
    } catch {
        return [pscustomobject]@{
            Failed = 1
            Error  = $_.Exception.Message
        }
    } finally {
        Remove-Item Env:\GITCLOUD_MUTATION_MODULE_ROOT -ErrorAction SilentlyContinue
    }
}

# Baseline: unmutated module must pass (oracle is valid).
$baselineRoot = Join-Path $env:TEMP ("SalmonRun-GitCloudMutation-$(Get-Random)-base")
Copy-Item -Path $modulesSrc -Destination $baselineRoot -Recurse -Force
$baseline = Invoke-Oracle -ModuleRoot $baselineRoot
Write-Host "Baseline oracle: Failed=$($baseline.Failed) Error=$($baseline.Error)"
if ($baseline.Failed -gt 0) {
    Write-Warning "Baseline oracle failed; mutants cannot be scored reliably."
}

$killed = 0
$total = 0
$results = @()

foreach ($m in $mutants) {
    $isEquivalent = $m.Id -in $equivalent
    if (-not $isEquivalent) { $total++ }

    $root = Join-Path $env:TEMP ("SalmonRun-GitCloudMutation-$(Get-Random)")
    Copy-Item -Path $modulesSrc -Destination $root -Recurse -Force

    $srcFile = Join-Path $root $m.File
    if (-not (Test-Path $srcFile)) {
        Write-Warning "Mutant $($m.Id): source file not found: $srcFile"
        $results += [pscustomobject]@{ Id = $m.Id; Killed = 'N/A'; Reason = 'source-missing' }
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        continue
    }

    $content = [System.IO.File]::ReadAllText($srcFile)
    if ($content.IndexOf($m.From, [System.StringComparison]::Ordinal) -lt 0) {
        Write-Warning "Mutant $($m.Id): 'From' pattern not found in $($m.File)"
        $results += [pscustomobject]@{ Id = $m.Id; Killed = 'N/A'; Reason = 'pattern-not-found' }
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        continue
    }
    $mutated = $content.Replace($m.From, $m.To)
    [System.IO.File]::WriteAllText($srcFile, $mutated, [System.Text.Encoding]::UTF8)

    $run = Invoke-Oracle -ModuleRoot $root
    $isKilled = ($run.Failed -gt 0) -or ($null -ne $run.Error)
    if (-not $isEquivalent -and $isKilled) { $killed++ }

    $results += [pscustomobject]@{
        Id     = $m.Id
        Killed = if ($isEquivalent) { 'equivalent' } elseif ($isKilled) { 'yes' } else { 'no' }
        Failed = $run.Failed
        Error  = $run.Error
    }
    Write-Host ("Mutant $($m.Id): " + $(if ($isEquivalent) { 'equivalent' } elseif ($isKilled) { 'KILLED' } else { 'SURVIVED' }) + " (failed=$($run.Failed))")
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item $baselineRoot -Recurse -Force -ErrorAction SilentlyContinue

$score = if ($total -gt 0) { [math]::Round(($killed / $total) * 100, 2) } else { 0 }
$summary = [pscustomobject]@{
    TotalMutants      = $mutants.Count
    ScoredMutants     = $total
    Killed            = $killed
    Survived          = ($total - $killed)
    Equivalent         = ($mutants.Count - $total)
    MutationScorePct  = $score
    ThresholdPct      = 95
    Passed            = ($score -ge 95)
    BaselineFailed    = $baseline.Failed
}

Write-Host ""
Write-Host "=== GitCloud Mutation Analysis ==="
Write-Host ($summary | ConvertTo-Json -Compress)
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $RepoRoot 'docs' 'gitcloud-mutation-score.json') -Encoding utf8
return $summary
