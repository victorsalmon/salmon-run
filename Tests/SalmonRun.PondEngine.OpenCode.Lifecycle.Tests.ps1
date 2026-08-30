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
                    defaults=@{harness='opencode';provider='opencode-go';effort='max';timeoutMinutes=3;costCeiling=50.0}
                    ponds=@{Code=@{challenge='Flash'};Review=@{challenge='Flash'};Audit=@{challenge='Daily'};QA=@{challenge='Daily'}}
                }
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runtime 'config.json') -NoNewline

            $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'target') -Force
            & git -C $target.FullName init -b main | Out-Null
            & git -C $target.FullName config user.email 'salmon-run-canary@example.invalid'
            & git -C $target.FullName config user.name 'Salmon Run Canary'
            '# OpenCode lifecycle canary' | Set-Content -LiteralPath (Join-Path $target 'README.md') -NoNewline
            & git -C $target.FullName add README.md
            & git -C $target.FullName commit -m 'test: initialize canary' | Out-Null

            $planName = '2026.08.30-opencode-canary.md'
            $plan = Join-Path $taskRoot "Code/$planName"
            @'
# OpenCode Go lifecycle canary
**Status**: ready
**Scope**: Implement and prove the isolated arithmetic canary only.
**Challenge**: Flash
**ConnascenceScope**: canary.ps1, tests/canary.tests.ps1, reports/salmon-run/qa-evidence-opencode-canary.json

## Acceptance Criteria

- `canary.ps1` exports `Get-CanaryValue` and returns integer 42.
- `tests/canary.tests.ps1` verifies the public behavior and exits nonzero when the value is mutated to 43.
- No file outside ConnascenceScope changes.

## Exact Validation Commands

- Secrets and documentation: inspect the three scoped files and confirm no credentials or broken references.
- Lint/static: `[scriptblock]::Create((Get-Content ./canary.ps1 -Raw)) | Out-Null`.
- Build: import `./canary.ps1` in a fresh PowerShell 7 process.
- Focused and full regression: `Invoke-Pester ./tests/canary.tests.ps1`.
- AQE: assess risk, blast radius, and proof for the three-file scope.

## Behavior and Invariant Risks

- The public command must always return an integer and exactly 42.
- Review must not modify repository files.

## Required Test Layers

- Focused example test in Code; complete one-behavior inventory and mutation proof in QA.

## Mutation Contract

- Temporarily replace `return 42` with `return 43` in an isolated copy, point the test at that copy, and require the test to fail; restore the original before completing.
- Scope is changed production code in `canary.ps1`; raw threshold is 95%, no waivers.

## Environment Prerequisites

- PowerShell 7 and Pester 6 are available. No network or external service is needed by the target project.

## Dependencies

- None.

## Resolved Pond Execution Profiles

- OpenCode Go from the isolated runtime configuration; tier selects the model for each pond.
'@ | Set-Content -LiteralPath $plan -NoNewline

            $namespace = & (Get-Module SalmonRun.PondEngine) { param($name) Get-PondFileNamespace -FileName $name } $planName
            Start-PondEngine -RepoDir $script:RepoRoot -TaskRoot $taskRoot -NamespaceRepoMap @{$namespace=$target.FullName} -MaxIterations 240 -PollIntervalSeconds 0 -SubprocessTimeoutMinutes 3

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
            Test-Path -LiteralPath (Join-Path $target 'reports/salmon-run/qa-evidence-opencode-canary.json') | Should -BeTrue
        } finally {
            if ($null -eq $savedHome) { Remove-Item Env:SALMON_RUN_HOME -ErrorAction SilentlyContinue } else { $env:SALMON_RUN_HOME = $savedHome }
            if ($null -eq $savedKey) { Remove-Item Env:OPENCODE_GO_KEY -ErrorAction SilentlyContinue } else { $env:OPENCODE_GO_KEY = $savedKey }
        }
    }
}
