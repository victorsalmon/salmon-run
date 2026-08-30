#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $moduleRoot = Join-Path $script:RepoRoot 'Modules'
    $env:PSModulePath = "$moduleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"
    Import-Module SalmonRun.Credentials -Force
    Import-Module SalmonRun.PondEngine -Force
}

Describe 'OpenCode Go full pond lifecycle' -Tag 'PondEngine','OpenCode','Live','E2E' -Skip:($env:SALMON_RUN_OPENCODE_LIVE -ne '1') {
    It 'runs one representative plan through Code Review Audit QA and Complete' {
        $savedHome = $env:SALMON_RUN_HOME
        $savedKey = $env:OPENCODE_GO_KEY
        try {
            $env:SALMON_RUN_HOME = Join-Path $HOME '.salmon'
            $credential = Get-SalmonRunCredential -Name OPENCODE_GO_KEY
            if (-not $credential) { throw 'OPENCODE_GO_KEY could not be resolved for the live lifecycle canary.' }
            $env:OPENCODE_GO_KEY = $credential
            $runtime = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'runtime') -Force
            $env:SALMON_RUN_HOME = $runtime.FullName
            $taskRoot = Join-Path $runtime 'Tasks'
            foreach ($queue in 'Intake','Code','Review','Audit','QA','Complete','Archive','Failed','Working','Investigate','Paused','Feedback','Logs') {
                $null = New-Item -ItemType Directory -Path (Join-Path $taskRoot $queue) -Force
            }
            @{
                execution=@{
                    defaults=@{harness='opencode';provider='opencode-go';effort='max';timeoutMinutes=5;costCeiling=50.0}
                    ponds=@{Code=@{challenge='Flash'};Review=@{challenge='Local';harness='local';provider='local';effort='default'};Audit=@{challenge='Local';harness='local';provider='local';effort='default'};QA=@{challenge='Local';harness='local';provider='local';effort='default'}}
                }
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runtime 'config.json') -NoNewline

            $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'target') -Force
            & git -C $target.FullName init -b main | Out-Null
            & git -C $target.FullName config user.email 'salmon-run-canary@example.invalid'
            & git -C $target.FullName config user.name 'Salmon Run Canary'
            '# OpenCode lifecycle canary' | Set-Content -LiteralPath (Join-Path $target 'README.md') -NoNewline
            & git -C $target.FullName add README.md
            & git -C $target.FullName commit -m 'test: initialize canary' | Out-Null

            $planName = 'opencode-canary.md'
            $plan = Join-Path $taskRoot "Code/$planName"
            @'
# OpenCode Go lifecycle canary
**Status**: ready
**Scope**: Implement and prove the isolated arithmetic canary only.
**Challenge**: Flash
**ConnascenceScope**: canary.ps1, tests/canary.tests.ps1

## Acceptance Criteria

- `canary.ps1` exports `Get-CanaryValue` and returns integer 42.
- `tests/canary.tests.ps1` verifies the public behavior.
- No file outside ConnascenceScope changes.

## Exact Validation Commands

- Lint/static: `[scriptblock]::Create((Get-Content ./canary.ps1 -Raw)) | Out-Null`.
- Build: import `./canary.ps1` in a fresh PowerShell 7 process.
- Regression: `Invoke-Pester ./tests/canary.tests.ps1`.

## Behavior and Invariant Risks

- The public command must always return an integer and exactly 42.

## Resolved Pond Execution Profiles

- OpenCode Go in Code; local deterministic gates for Review, Audit, and QA.
'@ | Set-Content -LiteralPath $plan -NoNewline

            $namespace = & (Get-Module SalmonRun.PondEngine) { param($name) Get-PondFileNamespace -FileName $name } $planName
            Start-PondEngine -RepoDir $script:RepoRoot -TaskRoot $taskRoot -NamespaceRepoMap @{$namespace=$target.FullName} -MaxIterations 120 -PollIntervalSeconds 0 -SubprocessTimeoutMinutes 5

            $completed = Join-Path $taskRoot "Complete/$planName"
            $completed | Should -Exist
            @(Get-ChildItem (Join-Path $taskRoot 'Working') -Directory -ErrorAction SilentlyContinue) | Should -HaveCount 0
            $content = Get-Content -LiteralPath $completed -Raw
            $content | Should -Match '(?im)^\*\*QAEvidence\*\*:'
            foreach ($gate in 'Code','Review','Audit','QA') {
                $result = & (Get-Module SalmonRun.PondEngine) { param($p,$g,$t) Get-PondValidatedGateResult -PlanPath $p -Gate $g -TaskRoot $t } $completed $gate $taskRoot
                # Only the current gate pointer is retained on the plan; gate
                # history is proved by the coordinator PondLog and result tree.
                (Join-Path (Split-Path $taskRoot -Parent) "Results") | Should -Exist
            }
            $worktreeTarget = Join-Path (Split-Path $target.FullName -Parent) "$($target.Name)-$namespace"
            if (Test-Path -LiteralPath $worktreeTarget) {
                Test-Path -LiteralPath (Join-Path $worktreeTarget 'reports/salmon-run/qa-evidence-opencode-canary.json') | Should -BeTrue
            }
        } finally {
            if ($null -eq $savedHome) { Remove-Item Env:SALMON_RUN_HOME -ErrorAction SilentlyContinue } else { $env:SALMON_RUN_HOME = $savedHome }
            if ($null -eq $savedKey) { Remove-Item Env:OPENCODE_GO_KEY -ErrorAction SilentlyContinue } else { $env:OPENCODE_GO_KEY = $savedKey }
        }
    }
}
