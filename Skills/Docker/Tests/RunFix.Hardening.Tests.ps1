#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = Resolve-Path "$PSScriptRoot/../../.."
    $script:RunFixPath = Join-Path $RepoRoot "Orchestrator/Orchestration/RunFix.ps1"
}

Describe "RunFix hardening" -Tag "RunFix", "Hardening" {
    Context "Subprocess timeout" {
        It "uses Start-Process with WaitForExit instead of direct & invocation" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'Start-Process.*-PassThru'
            $content | Should -Match 'WaitForExit'
        }

        It "respects RUNFIX_TIMEOUT_SECONDS env var (default 300)" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'RUNFIX_TIMEOUT_SECONDS'
            $content | Should -Match '\$runfixTimeoutSec'
        }

        It "kills process on timeout and returns TIMEOUT output" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'Stop-Process'
            $content | Should -Match 'TIMEOUT'
        }
    }

    Context "Context-gated exit" {
        It "tracks consecutive identical rubric failures" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'consecutiveIdenticalFailures'
        }

        It "exits 99 after 5 consecutive identical failures (threshold ge 4)" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'exit 99'
            $content | Should -Match '-ge 4'
        }

        It "writes handoff file on context gate" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'runfix-context-gate'
        }

        It "handoff is written to Tasks/Handoff/ via repoRoot" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'Join-Path \$repoRoot \"Tasks\" \"Handoff\"'
        }
    }

    Context "Preflight re-checks" {
        It "verifies target script exists at top of each cycle" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'Test-Path \$targetScript'
        }

        It "aborts with exit 1 if target script is missing" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'exit 1'
        }

        It "checks wall time against RUNFIX_MAX_WALL_MINUTES (default 60)" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'RUNFIX_MAX_WALL_MINUTES'
            $content | Should -Match '\$runfixMaxWallMinutes'
        }

        It "aborts with exit 1 if wall time exceeded" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'wall time'
        }

        It "validates targetScript is not null/empty before Test-Path" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'IsNullOrEmpty.*targetScript'
        }
    }

    Context "Preflight opencode CLI check" {
        It "checks for opencode CLI before main loop" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'opencode CLI found'
        }

        It "exits 1 when opencode CLI is not found" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'opencode CLI not found'
        }
    }

    Context "Output capture includes stderr" {
        It "reads stderr file and merges into output" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'Get-Content \$errFile'
            $content | Should -Match '\$output, \$stderr'
        }
    }

    Context "Log path uniqueness" {
        It "includes PID in log filename" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'pid\$\{?pid\}?'
            $content | Should -Match '\$PID'
        }

        It "includes PID in cycle output filename" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'pid\$\{?pid\}?-cycle'
        }

        It "includes PID in context file" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'context.*pid'
        }

        It "includes PID in handoff filename" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'context-gate.*pid'
        }
    }

    Context "Encoding" {
        It "uses -Encoding UTF8 on Add-Content" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'Add-Content.*-Encoding UTF8'
        }
    }

    Context "Repo root resolution" {
        It "falls back to PSScriptRoot/../.. for repo root" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'PSScriptRoot/\.\./\.\.'
        }

        It "handoff dir uses repoRoot not PSScriptRoot" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Not -Match 'PSScriptRoot.*Tasks.*Handoff'
            $content | Should -Match 'Join-Path \$repoRoot'
        }
    }

    Context "Goals file re-read (self-modification support)" {
        It "re-reads goals file before each cycle" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'Re-read goals file config for values LLM may have updated'
        }

        It "re-parses \$FLAGS from re-read config" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match '\$defaultFlags = if \(\$config\.ContainsKey'
        }

        It "re-parses rubric patterns from re-read config" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match '\$rubricSuccessPatterns = @\(\)'
        }

        It "re-parses error table from re-read config" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match '\$errorTable = @\(\)'
        }
    }

    Context "Rubric content matching (success signal)" {
        It "checks Log contains patterns in addition to exit code" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match '\$rubricSuccessPatterns'
        }

        It "localorchestrator goals file has machine-parseable Log contains row" {
            $goalsPath = Join-Path $RepoRoot "Skills/Workflows/RunFix/runfix-localorchestrator.md"
            $goals = Get-Content $goalsPath -Raw
            $goals | Should -Match 'Log contains.*All queues empty'
        }
    }

    Context "Executor-aware terminal checks" -Tag "RunFix", "Hardening" {
        It "extracts executor from \$FLAGS at initial config parse" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match '\$script:runfixExecutor = if \('
        }

        It "re-extracts executor from \$FLAGS on goals file re-read" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match '\$script:runfixExecutor = if \(\$defaultFlags -match'
        }

        It "defaults executor to \$null when no -Executor flag present" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'else \{ \$null \}'
        }

        It "gates AWS SSO and Docker checks behind \$executorNeedsAws" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'if \(\$executorNeedsAws\)'
        }

        It "still checks disk space and network for all executors" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'Disk space'
            $content | Should -Match 'Network'
        }

        It "logs when AWS/Docker checks are skipped for local executor" {
            $content = Get-Content $script:RunFixPath -Raw
            $content | Should -Match 'AWS SSO and Docker checks skipped'
        }

        It "runfix-localorchestrator.md documents executor-terminal-check mapping" {
            $goalsPath = Join-Path $RepoRoot "Skills/Workflows/RunFix/runfix-localorchestrator.md"
            $goals = Get-Content $goalsPath -Raw
            $goals | Should -Match 'Terminal checks.*Executor `local` skips AWS SSO and Docker checks'
        }
    }

    Context "Script parses without syntax errors" {
        It "RunFix.ps1 parses without errors" {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($script:RunFixPath, [ref]$null, [ref]$errors)
            $errors.Count | Should -Be 0
        }
    }
}
